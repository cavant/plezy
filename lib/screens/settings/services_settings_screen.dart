import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/catalog/catalog_item.dart';
import '../../providers/seerr_account_provider.dart';
import '../../services/discord_rpc_service.dart';
import '../../services/home_assistant_sync_service.dart';
import '../../services/settings_service.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/catalog_source_logo.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'seerr_connect_screen.dart';
import 'seerr_settings_screen.dart';
import 'tracker_service_info.dart';

/// Unified hub for all connected services: the watch-progress trackers
/// (Trakt, MyAnimeList, AniList, Simkl) and the Seerr request server. Each
/// row opens its service-specific settings screen.
class ServicesSettingsScreen extends StatelessWidget {
  const ServicesSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.services.title),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                t.services.hubSubtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            SettingsGroup(children: [for (final info in TrackerServiceInfo.all) _TrackerHubRow(info), _seerr()]),
            if (DiscordRPCService.isAvailable)
              SettingsGroup(
                title: t.services.integrations,
                children: [
                  SettingSwitchTile(
                    pref: SettingsService.enableDiscordRPC,
                    icon: Symbols.chat_rounded,
                    title: t.settings.discordRichPresence,
                    subtitle: t.settings.discordRichPresenceDescription,
                  ),
                ],
              ),
            SettingsGroup(
              title: 'Smart Home (Home Assistant)',
              children: [
                SettingSwitchTile(
                  pref: SettingsService.homeAssistantWebhookEnabled,
                  icon: Symbols.home_rounded,
                  title: 'Home Assistant Webhook',
                  subtitle: 'Zero-latency play/pause/stop sync for smart lighting and automations',
                ),
                SettingStringTile(
                  pref: SettingsService.homeAssistantWebhookUrl,
                  icon: Symbols.link_rounded,
                  title: 'Webhook URL',
                  subtitle: 'HTTP endpoint for Home Assistant automation trigger',
                  defaultValue: 'http://192.168.1.114/api/webhook/plezy_playback',
                  labelText: 'Home Assistant Webhook URL',
                ),
                FocusableListTile(
                  leading: const AppIcon(Symbols.bolt_rounded, fill: 1),
                  title: const Text('Test Webhook Connection'),
                  subtitle: const Text('Send an instant test ping to Home Assistant'),
                  trailing: const AppIcon(Symbols.send_rounded, fill: 1),
                  onTap: () async {
                    showAppSnackBar(context, 'Sending test ping to Home Assistant...');
                    final success = await HomeAssistantSyncService.instance.sendTestPing();
                    if (context.mounted) {
                      if (success) {
                        showAppSnackBar(context, 'Home Assistant webhook responded successfully!');
                      } else {
                        showErrorSnackBar(context, 'Could not reach Home Assistant webhook URL');
                      }
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ],
    );
  }

  Widget _seerr() => Consumer<SeerrAccountProvider>(
    builder: (context, account, _) => _ServiceHubRow(
      leading: const CatalogSourceLogo(CatalogSourceId.seerr, size: 24),
      title: t.services.names.seerr,
      username: account.isConnected ? account.displayName : null,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => account.isConnected ? const SeerrSettingsScreen() : const SeerrConnectScreen(),
          ),
        );
      },
    ),
  );
}

/// Hub row for a watch tracker. Owns the `watch` on that service's account
/// provider so only this row rebuilds when the connection state changes.
class _TrackerHubRow extends StatelessWidget {
  final TrackerServiceInfo info;

  const _TrackerHubRow(this.info);

  @override
  Widget build(BuildContext context) {
    final connected = info.isConnected(context);
    return _ServiceHubRow(
      leading: CatalogSourceLogo(info.logoSource, size: 24),
      title: info.displayName,
      username: connected ? info.username(context) : null,
      onTap: () {
        if (connected) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => info.buildSettingsScreen()));
        } else {
          info.startConnection(context);
        }
      },
    );
  }
}

class _ServiceHubRow extends StatelessWidget {
  final Widget leading;
  final String title;

  /// Non-null when connected. When null, the subtitle shows "Not connected".
  final String? username;

  final VoidCallback onTap;

  const _ServiceHubRow({required this.leading, required this.title, required this.username, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FocusableListTile(
      leading: leading,
      title: Text(title),
      subtitle: Text(username != null ? t.services.connectedAs(username: username!) : t.services.notConnected),
      trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
      onTap: onTap,
    );
  }
}
