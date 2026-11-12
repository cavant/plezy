import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../media/media_item.dart';
import '../utils/app_logger.dart';
import 'settings_service.dart';
import 'shield_optimization_service.dart';

/// Zero-latency smart home bridge for Home Assistant automations.
///
/// Sends instantaneous JSON webhook events on playback state transitions
/// (play, pause, stop) or media item changes to the user's local Home Assistant
/// instance (e.g. at 192.168.1.114) so lights, soundbars, and room automations
/// trigger with zero delay and never re-trigger during steady-state playback.
class HomeAssistantSyncService {
  HomeAssistantSyncService._internal();
  static final HomeAssistantSyncService instance = HomeAssistantSyncService._internal();

  String? _lastReportedState;
  String? _lastReportedMediaKey;

  String _normalizeWebhookUrl(String url) {
    var trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.contains('192.168.1.114:8123')) {
      trimmed = trimmed.replaceFirst('192.168.1.114:8123', '192.168.1.114');
      unawaited(SettingsService.instance.write(SettingsService.homeAssistantWebhookUrl, trimmed));
    }
    return trimmed;
  }

  /// Dispatch a playback lifecycle event to Home Assistant and trigger Shield
  /// playback-start optimizations when transitioning into 'playing'.
  Future<void> reportEvent({
    required String state, // 'playing', 'paused', 'stopped'
    required MediaItem metadata,
    required Duration position,
    required Duration duration,
    String? playerType,
    String? videoCodec,
    String? audioCodec,
    String? colorTransfer,
  }) async {
    final mediaKey = metadata.globalKey;
    final isStateChange = _lastReportedState != state;
    final isMediaChange = _lastReportedMediaKey != mediaKey;

    // Only act on genuine playback state transitions or media item changes so
    // periodic 10s progress ticks never spam Home Assistant or soundbar scripts.
    if (!isStateChange && !isMediaChange) {
      return;
    }

    _lastReportedState = state;
    _lastReportedMediaKey = mediaKey;

    if (state == 'playing') {
      unawaited(ShieldOptimizationService.instance.onPlaybackStart());
    }

    final settings = SettingsService.instance;
    final enabled = settings.read(SettingsService.homeAssistantWebhookEnabled);
    if (!enabled) return;

    final rawUrl = settings.read(SettingsService.homeAssistantWebhookUrl);
    final webhookUrl = _normalizeWebhookUrl(rawUrl);
    if (webhookUrl.isEmpty) return;

    final now = DateTime.now();
    final double progressPercent = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds) * 100
        : 0.0;

    final payload = {
      'event': state,
      'title': metadata.title,
      'series': metadata.grandparentTitle,
      'season': metadata.parentIndex,
      'episode': metadata.index,
      'year': metadata.year,
      'type': metadata.kind.name,
      'position_ms': position.inMilliseconds,
      'duration_ms': duration.inMilliseconds,
      'progress_percent': double.parse(progressPercent.toStringAsFixed(1)),
      'video_codec': videoCodec,
      'audio_codec': audioCodec,
      'color_transfer': colorTransfer,
      'player': playerType ?? 'mpv',
      'device': Platform.isAndroid ? 'NVIDIA Shield TV' : Platform.operatingSystem,
      'timestamp': now.toIso8601String(),
    };

    try {
      final uri = Uri.parse(webhookUrl);
      unawaited(
        http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(milliseconds: 1500))
            .then((response) {
              appLogger.d('Home Assistant webhook [$state] responded: ${response.statusCode}');
            })
            .catchError((error) {
              appLogger.d('Home Assistant webhook dispatch non-fatal failure: $error');
            }),
      );
    } catch (e) {
      appLogger.d('Home Assistant invalid webhook URL: $e');
    }
  }

  /// Fire a test ping to verify connectivity with the configured Home Assistant webhook.
  Future<bool> sendTestPing() async {
    final settings = SettingsService.instance;
    final rawUrl = settings.read(SettingsService.homeAssistantWebhookUrl);
    final webhookUrl = _normalizeWebhookUrl(rawUrl);
    if (webhookUrl.isEmpty) return false;

    try {
      final uri = Uri.parse(webhookUrl);
      final testPayload = {
        'event': 'test_ping',
        'title': 'Plezy Test Ping',
        'device': Platform.isAndroid ? 'NVIDIA Shield TV' : Platform.operatingSystem,
        'timestamp': DateTime.now().toIso8601String(),
      };
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(testPayload),
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      appLogger.w('Home Assistant test ping failed: $e');
      return false;
    }
  }
}
