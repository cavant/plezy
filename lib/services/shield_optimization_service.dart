import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import 'device_performance.dart';
import 'settings_service.dart';

/// Self-contained NVIDIA Shield TV & Low-RAM Android TV optimization service.
///
/// Consolidates all 4K Dolby Vision / HDR10 10-bit hardware decode, MPV queue,
/// OSD subtitle plane, Skia GPU cache, and background process memory trimming
/// optimizations behind a single Settings toggle (`SettingsService.shieldOptimizationEnabled`)
/// so core upstream player and surface files remain 100% unmodified.
class ShieldOptimizationService {
  ShieldOptimizationService._internal();
  static final ShieldOptimizationService instance = ShieldOptimizationService._internal();

  static const MethodChannel _channel = MethodChannel('com.plezy/shield_custom');

  static const String _blockStart = '# [SHIELD_OPTIMIZATION_START]';
  static const String _blockEnd = '# [SHIELD_OPTIMIZATION_END]';

  /// Managed MPV properties applied via `SettingsService.mpvConfigText` whenever
  /// the NVIDIA Shield TV optimization toggle is enabled.
  ///
  /// - `vd-queue-*`: Caps MediaCodec decoded frame queue to 3 frames / 16 MiB so
  ///   4K 10-bit HEVC / Dolby Vision frame surfaces never exhaust the 3 GB Shield RAM.
  /// - `demuxer-max-*` & `stream-buffer-size`: Bounds demuxer packet arena to
  ///   48 MiB forward / 16 MiB back / 16 MiB stream buffer.
  /// - `glsl-shaders=`: Clears active GLSL shaders so `vo=mediacodec` direct
  ///   hardware overlay is never hijacked by `vo=gpu` on 10-bit HDR10 / DoVi content.
  static const String _managedMpvBlock = '''$_blockStart
vd-queue-enable=yes
vd-queue-max-samples=3
vd-queue-max-secs=0.15
vd-queue-max-bytes=16MiB
demuxer-max-bytes=48MiB
demuxer-max-back-bytes=16MiB
stream-buffer-size=16777216
glsl-shaders=
$_blockEnd''';

  static const int _shieldSkiaCacheMaxBytes = 48 << 20; // 48 MiB

  /// Called during `SettingsService.onInit()` to apply or reconcile the
  /// NVIDIA Shield TV optimizations according to the persisted toggle state.
  Future<void> onSettingsInitialized(SettingsService settings) async {
    if (!Platform.isAndroid) return;
    final enabled = settings.read(SettingsService.shieldOptimizationEnabled);
    if (enabled) {
      await _applyEnabledState(settings, runMemoryTrim: true);
    }
  }

  /// Toggle NVIDIA Shield TV optimizations on or off from the Settings UI.
  Future<void> setEnabled(SettingsService settings, bool enabled) async {
    await settings.write(SettingsService.shieldOptimizationEnabled, enabled);
    if (enabled) {
      await _applyEnabledState(settings, runMemoryTrim: true);
    } else {
      await _applyDisabledState(settings);
    }
  }

  /// Triggered when video playback transitions to `'playing'`.
  Future<void> onPlaybackStart() async {
    if (!Platform.isAndroid) return;
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return;
    if (!settings.read(SettingsService.shieldOptimizationEnabled)) return;

    _capSkiaResourceCache();
    unawaited(trimBackgroundMemory());
  }

  Future<void> _applyEnabledState(SettingsService settings, {required bool runMemoryTrim}) async {
    final currentMpvText = settings.read(SettingsService.mpvConfigText);
    final updatedMpvText = _upsertManagedBlock(currentMpvText);
    if (updatedMpvText != currentMpvText) {
      await settings.write(SettingsService.mpvConfigText, updatedMpvText);
    }

    if (settings.read(SettingsService.subtitleRenderResolution) != SubtitleRenderResolution.half) {
      await settings.write(SettingsService.subtitleRenderResolution, SubtitleRenderResolution.half);
    }

    if (settings.read(SettingsService.visualEffects) != VisualEffectsSetting.reduced) {
      await settings.write(SettingsService.visualEffects, VisualEffectsSetting.reduced);
    }
    DevicePerformance.setOverrideSync(VisualEffectsSetting.reduced);

    if (settings.read(SettingsService.globalShaderPreset) != 'none') {
      await settings.write(SettingsService.globalShaderPreset, 'none');
    }

    _capSkiaResourceCache();

    if (runMemoryTrim) {
      unawaited(trimBackgroundMemory());
    }
  }

  Future<void> _applyDisabledState(SettingsService settings) async {
    final currentMpvText = settings.read(SettingsService.mpvConfigText);
    final cleanedMpvText = _removeManagedBlock(currentMpvText);
    if (cleanedMpvText != currentMpvText) {
      await settings.write(SettingsService.mpvConfigText, cleanedMpvText);
    }

    if (settings.read(SettingsService.subtitleRenderResolution) == SubtitleRenderResolution.half) {
      await settings.write(SettingsService.subtitleRenderResolution, SubtitleRenderResolution.screen);
    }

    if (settings.read(SettingsService.visualEffects) == VisualEffectsSetting.reduced) {
      await settings.write(SettingsService.visualEffects, VisualEffectsSetting.auto);
    }
    DevicePerformance.setOverrideSync(VisualEffectsSetting.auto);
  }

  void _capSkiaResourceCache() {
    if (!Platform.isAndroid) return;
    unawaited(
      SystemChannels.skia
          .invokeMethod<void>('Skia.setResourceCacheMaxBytes', _shieldSkiaCacheMaxBytes)
          .catchError((_) {}),
    );
  }

  String _upsertManagedBlock(String existing) {
    final stripped = _removeManagedBlock(existing).trim();
    if (stripped.isEmpty) {
      return _managedMpvBlock;
    }
    return '$stripped\n\n$_managedMpvBlock';
  }

  String _removeManagedBlock(String existing) {
    final startIdx = existing.indexOf(_blockStart);
    if (startIdx == -1) return existing;
    final endIdx = existing.indexOf(_blockEnd, startIdx);
    if (endIdx == -1) {
      return existing.substring(0, startIdx).trimRight();
    }
    final before = existing.substring(0, startIdx).trimRight();
    final after = existing.substring(endIdx + _blockEnd.length).trimLeft();
    if (before.isEmpty) return after;
    if (after.isEmpty) return before;
    return '$before\n$after';
  }

  /// Invoke native `ShieldMemoryOptimizer.trimBackgroundProcesses` on Android.
  Future<Map<String, dynamic>?> trimBackgroundMemory() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('trimBackgroundMemory');
      if (result != null) {
        final freedMb = ((result['freedBytes'] as int? ?? 0) / (1024 * 1024)).round();
        final availMb = ((result['availMem'] as int? ?? 0) / (1024 * 1024)).round();
        appLogger.i('ShieldOptimizationService: trimmed background memory (freed ~${freedMb}MB, avail ${availMb}MB)');
      }
      return result;
    } catch (e) {
      appLogger.d('ShieldOptimizationService: trimBackgroundMemory skipped: $e');
      return null;
    }
  }
}
