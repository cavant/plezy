import 'dart:convert';

import '../models/plex/plex_home.dart';
import '../models/plex/plex_home_user.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile.dart';
import '../profiles/profile_registry.dart';
import '../services/plex_auth_service.dart';
import '../services/seerr/seerr_auth_service.dart';
import '../services/seerr/seerr_session_store.dart';
import '../services/server_registry.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import 'connection.dart';
import 'connection_registry.dart';
import 'plex_account_setup.dart';

/// One-shot helpers that bridge between the legacy single-Plex-account
/// SharedPreferences state (`StorageService.plexToken` +
/// `currentUserUUID` + `homeUsersCache` + `ServerRegistry.getServers()`)
/// and the new [ConnectionRegistry] world.
///
/// Plex Home users are NOT persisted here — the bootstrap copies the
/// legacy `homeUsersCache` into the per-connection
/// `plex_home_users_{connectionId}` SharedPreferences slot and asks
/// [PlexHomeService] to reload (or fetch) it.
class ConnectionBootstrap {
  ConnectionBootstrap({
    required this.storage,
    required this.connectionRegistry,
    required this.serverRegistry,
    required this.profileRegistry,
    required this.plexHome,
    Future<Map<String, dynamic>> Function(String accountToken)? plexUserInfoFetcher,
  }) : _plexUserInfoFetcher = plexUserInfoFetcher ?? _fetchPlexUserInfo;

  final StorageService storage;
  final ConnectionRegistry connectionRegistry;
  final ServerRegistry serverRegistry;
  final ProfileRegistry profileRegistry;
  final PlexHomeService plexHome;
  final Future<Map<String, dynamic>> Function(String accountToken) _plexUserInfoFetcher;

  static const String _keyProfileMigrationV1Done = 'profile_migration_v1_done';

  /// Run all idempotent boot-time migrations. Best-effort — errors are
  /// logged but never thrown.
  Future<void> run() async {
    final seededDevAccount = await seedFromDevTokenDefine();
    final hadLegacyPlexToken = (storage.getPlexToken() ?? '').isNotEmpty;
    final hadLegacyProfileState = _hasLegacyProfileState();
    final migratedAccount = await migrateLegacyPlexAccount();
    final account = await _firstPlexAccount(migratedAccount);
    final alreadyMigrated = storage.prefs.getBool(_keyProfileMigrationV1Done) ?? false;
    if (!alreadyMigrated) {
      if (account == null && (hadLegacyPlexToken || hadLegacyProfileState)) {
        appLogger.w('Migration: legacy profile state present but Plex account was not migrated; will retry later');
        return;
      }
      // Drop any plex_home rows left over from the pre-refactor data
      // model — Plex Home users are now fetched live, never persisted.
      final droppedPlexHomeRows = await profileRegistry.dropAllPlexHomeRows();
      // Only a legacy install has a profile selection to carry over. Without
      // legacy state the flag is missing because the install is fresh or
      // because a preference-store repair lost it (with the active profile)
      // while the database kept the migrated accounts; selecting the Home
      // admin then would auto-resume it on this boot, skipping the picker
      // and its PIN.
      final hasSelectionToMigrate =
          hadLegacyPlexToken || hadLegacyProfileState || droppedPlexHomeRows > 0 || seededDevAccount;
      if (account != null && hasSelectionToMigrate) {
        final prepared = await _preparePlexVirtualProfile(account);
        if (!prepared) {
          if (migratedAccount != null && hadLegacyPlexToken) {
            // A failed/empty fetch may have left an empty cache slot on disk
            // for the id we are about to drop; don't leave it orphaned.
            await storage.clearPlexHomeUsersCache(migratedAccount.id);
            await connectionRegistry.remove(migratedAccount.id);
          }
          appLogger.w('Migration: could not hydrate Plex Home profiles for ${account.id}; will retry later');
          return;
        }
      }
      if (hadLegacyPlexToken) {
        await storage.clearLegacyPlexToken();
      }
      await storage.clearServersList();
      await storage.prefs.setBool(_keyProfileMigrationV1Done, true);
    } else {
      await storage.clearServersList();
      await _recoverLegacyProfilePromotionIfNeeded(account);
      await _migrateLegacyPlexHomeUsersCacheForExistingAccount(account);
    }
    await _seedServicesIfDefined(account);
  }

  Future<void> _seedServicesIfDefined(PlexAccountConnection? account) async {
    // 1. Home Assistant Webhook URL
    const haWebhook = String.fromEnvironment('HA_WEBHOOK_URL');
    if (haWebhook.isNotEmpty) {
      final settings = SettingsService.instance;
      await settings.write(SettingsService.homeAssistantWebhookUrl, haWebhook);
      await settings.write(SettingsService.homeAssistantWebhookEnabled, true);
      appLogger.i('Pre-seeded Home Assistant webhook URL: $haWebhook');
    }

    // 2. Overseerr / Seerr Session
    const overseerrUrl = String.fromEnvironment('OVERSEERR_URL');
    if (overseerrUrl.isNotEmpty) {
      try {
        final targetAccount = account ?? await _firstPlexAccount(null);
        final activeProfileId = storage.getActiveProfileId();
        final userScope = activeProfileId != null ? profileUserScope(activeProfileId) : '';
        if (userScope.isNotEmpty) {
          const store = SeerrSessionStore();
          final existing = await store.load(userScope);
          if (existing == null) {
            final plexToken = targetAccount?.accountToken ?? const String.fromEnvironment('PLEX_TOKEN');
            if (plexToken.isNotEmpty) {
              appLogger.i('Pre-seeding Overseerr session for $overseerrUrl with Plex auth...');
              final authService = SeerrAuthService();
              final session = await authService.signInWithPlex(
                baseUrl: overseerrUrl,
                plexToken: plexToken,
              );
              await store.save(userScope, session);
              appLogger.i('Pre-seeded Overseerr session for ${session.displayName} (user_id: ${session.userId})');
            }
          }
        }
      } catch (e, st) {
        appLogger.w('Overseerr pre-seeding non-fatal failure: $e', error: e, stackTrace: st);
      }
    }
  }

  bool _hasLegacyProfileState() {
    return (storage.getCurrentUserUUID() ?? '').isNotEmpty ||
        (storage.prefs.getString('home_users_cache') ?? '').isNotEmpty;
  }

  /// Screenshot automation injects a Plex token via the `PLEX_TOKEN`
  /// dart-define so the app boots already-signed-in. Inserts a
  /// [PlexAccountConnection] directly when the env var is non-empty AND
  /// the registry doesn't already have a Plex account, fetching the user
  /// info + servers like the auth screen does. No-op in normal builds.
  /// Returns whether an account was seeded.
  Future<bool> seedFromDevTokenDefine() async {
    const devToken = String.fromEnvironment('PLEX_TOKEN');
    if (devToken.isEmpty) return false;
    final existing = await connectionRegistry.list();
    if (existing.whereType<PlexAccountConnection>().isNotEmpty) return false;

    try {
      final build = await buildPlexAccountConnection(devToken, keyByAccountUuid: false, tolerateUserInfoFailure: true);
      const directUrl = String.fromEnvironment('PLEX_DIRECT_URL');
      var connection = build.connection;
      if (directUrl.isNotEmpty) {
        final uri = Uri.tryParse(directUrl);
        if (uri != null) {
          final directConn = PlexConnection(
            protocol: uri.scheme,
            address: uri.host,
            port: uri.port,
            uri: directUrl,
            local: true,
            relay: false,
            ipv6: false,
          );
          if (connection.servers.isNotEmpty) {
            final updatedServers = connection.servers.map((s) {
              final conns = [directConn, ...s.connections.where((c) => c.uri != directUrl)];
              return PlexServer(
                name: s.name,
                clientIdentifier: s.clientIdentifier,
                accessToken: s.accessToken,
                connections: conns,
                owned: s.owned,
                product: s.product,
                platform: s.platform,
                lastSeenAt: s.lastSeenAt,
              );
            }).toList();
            connection = connection.copyWith(servers: updatedServers);
          } else {
            const serverMachineId = String.fromEnvironment(
              'PLEX_SERVER_MACHINE_ID',
              defaultValue: 'd073e7ea34bc20bbc1ce17d048effb8e7f751861',
            );
            final directServer = PlexServer(
              name: 'Plex Server',
              clientIdentifier: serverMachineId,
              accessToken: devToken,
              connections: [directConn],
              owned: true,
            );
            connection = connection.copyWith(servers: [directServer]);
          }
        }
      }
      await connectionRegistry.upsert(connection);
      appLogger.i('Seeded Plex account from PLEX_TOKEN dart-define as ${connection.id}');
      return true;
    } catch (e, st) {
      appLogger.w('PLEX_TOKEN seed failed', error: e, stackTrace: st);
      return false;
    }
  }

  /// If a legacy Plex token sits in [StorageService] without a corresponding
  /// row in [ConnectionRegistry], wrap it as a [PlexAccountConnection] and
  /// insert. Best-effort: errors are logged but never thrown.
  Future<PlexAccountConnection?> migrateLegacyPlexAccount() async {
    final token = storage.getPlexToken();
    if (token == null || token.isEmpty) return null;

    final existing = await connectionRegistry.list();
    final alreadyMigrated = existing
        .whereType<PlexAccountConnection>()
        .where((c) => c.accountToken == token)
        .firstOrNull;
    if (alreadyMigrated != null) {
      return alreadyMigrated;
    }

    try {
      final build = await buildPlexAccountConnection(
        token,
        clientIdentifier: await storage.getOrCreateClientIdentifier(),
        fetchUserInfo: _plexUserInfoFetcher,
        // The migration wraps the cached legacy server list; a network server
        // fetch could fail exactly when the migration must succeed offline.
        fetchServers: (_) => serverRegistry.getServers(),
      );
      await connectionRegistry.upsert(build.connection);
      appLogger.i('Migrated legacy Plex account into ConnectionRegistry as ${build.connection.id}');
      return build.connection;
    } catch (e, st) {
      appLogger.w('Plex account migration failed', error: e, stackTrace: st);
      return null;
    }
  }

  /// Hydrate Plex Home users for [account] and select a virtual Plex Home
  /// profile. Plex users are never persisted as local Plezy profiles.
  Future<bool> _preparePlexVirtualProfile(PlexAccountConnection account) async {
    final copied = await _migrateLegacyPlexHomeUsersCache(account.id);
    if (copied) {
      await plexHome.reloadFromStorage();
    } else {
      await plexHome.refresh(account);
    }
    final hydratedUsers = plexHome.current[account.id] ?? const [];
    if (hydratedUsers.isEmpty) return false;

    final legacyActiveUuid = storage.getCurrentUserUUID();
    PlexHomeUser selected;
    if (legacyActiveUuid != null && legacyActiveUuid.isNotEmpty) {
      selected = hydratedUsers.firstWhere(
        (u) => u.uuid == legacyActiveUuid,
        orElse: () => _preferredPlexHomeUser(hydratedUsers),
      );
      if (selected.uuid != legacyActiveUuid) {
        appLogger.w('Migration: legacy Plex Home UUID $legacyActiveUuid not found; using ${selected.uuid} instead');
      }
    } else {
      selected = _preferredPlexHomeUser(hydratedUsers);
    }

    final activeProfileId = plexHomeProfileId(accountConnectionId: account.id, homeUserUuid: selected.uuid);
    await storage.setActiveProfileId(activeProfileId);
    await storage.clearCurrentUserUUID();
    await Future.wait([storage.prefs.remove('home_users_cache'), storage.prefs.remove('home_users_cache_expiry')]);
    appLogger.i('Migration: selected Plex Home profile ${selected.displayName} → $activeProfileId');
    return true;
  }

  PlexHomeUser _preferredPlexHomeUser(List<PlexHomeUser> users) {
    return users.firstWhere((u) => u.admin, orElse: () => users.first);
  }

  Future<bool> _migrateLegacyPlexHomeUsersCache(String connectionId) async {
    final raw = storage.prefs.getString('home_users_cache');
    if (raw == null || raw.isEmpty) return false;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      final home = PlexHome.fromJson(decoded);
      if (home.users.isEmpty) return false;
      await storage.savePlexHomeUsersCache(connectionId, home.users.map((u) => u.toJson()).toList());
      appLogger.i('Migration: copied ${home.users.length} Plex Home users into cache for $connectionId');
      return true;
    } catch (e, st) {
      appLogger.w('Plex Home cache migration failed', error: e, stackTrace: st);
      return false;
    }
  }

  Future<void> _migrateLegacyPlexHomeUsersCacheForExistingAccount(PlexAccountConnection? account) async {
    if (storage.prefs.getString('home_users_cache') == null) return;
    var target = account;
    if (target == null) {
      final connections = await connectionRegistry.list();
      for (final conn in connections) {
        if (conn is PlexAccountConnection) {
          target = conn;
          break;
        }
      }
    }
    if (target == null) return;
    final copied = await _migrateLegacyPlexHomeUsersCache(target.id);
    if (copied) {
      await Future.wait([storage.prefs.remove('home_users_cache'), storage.prefs.remove('home_users_cache_expiry')]);
    }
  }

  Future<PlexAccountConnection?> _firstPlexAccount(PlexAccountConnection? preferred) async {
    if (preferred != null) return preferred;
    final connections = await connectionRegistry.list();
    for (final conn in connections) {
      if (conn is PlexAccountConnection) return conn;
    }
    return null;
  }

  Future<void> _recoverLegacyProfilePromotionIfNeeded(PlexAccountConnection? account) async {
    if (!_hasLegacyProfileState()) return;
    final target = await _firstPlexAccount(account);
    if (target == null) return;
    await _preparePlexVirtualProfile(target);
  }
}

Future<Map<String, dynamic>> _fetchPlexUserInfo(String accountToken) async {
  final auth = await PlexAuthService.create();
  try {
    return await auth.getUserInfo(accountToken);
  } finally {
    auth.dispose();
  }
}
