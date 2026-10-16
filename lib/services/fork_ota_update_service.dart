// Custom In-App OTA Updater Service for Plezy on Android / NVIDIA Shield TV
// Replaces the browser URL launcher with a direct in-place APK downloader and installer.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'update_service.dart';

class ForkOtaUpdateService {
  static const String repoOwner = "cavant";
  static const String repoName = "plezy";
  static const MethodChannel _deviceChannel = MethodChannel('com.plezy/device');

  static String get latestReleaseApiUrl =>
      "https://api.github.com/repos/$repoOwner/$repoName/releases/latest";

  /// Checks if a new release is available on GitHub
  static Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse(latestReleaseApiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode != 200) return null;

      final releaseData = jsonDecode(response.body) as Map<String, dynamic>;
      final remoteTag = (releaseData['tag_name'] as String?)?.replaceFirst('v', '') ?? '';

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (_isRemoteNewer(currentVersion, remoteTag)) {
        return releaseData;
      }
    } catch (e) {
      debugPrint("Error checking for update: $e");
    }
    return null;
  }

  /// Determines device ABI and finds matching APK asset in release data
  static Future<String?> getDownloadUrlForDevice(Map<String, dynamic> releaseData) async {
    List<dynamic>? assets = releaseData['assets'] as List<dynamic>?;
    if (assets == null || assets.isEmpty) {
      try {
        final response = await http.get(
          Uri.parse(latestReleaseApiUrl),
          headers: {'Accept': 'application/vnd.github.v3+json'},
        );
        if (response.statusCode == 200) {
          final fetched = jsonDecode(response.body) as Map<String, dynamic>;
          assets = fetched['assets'] as List<dynamic>?;
        }
      } catch (_) {}
    }
    assets ??= [];

    // Detect primary ABI on Android
    String preferredArch = "arm64-v8a"; // Default for NVIDIA Shield TV
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final supportedAbis = androidInfo.supportedAbis;
      if (supportedAbis.contains("arm64-v8a")) {
        preferredArch = "arm64-v8a";
      } else if (supportedAbis.contains("armeabi-v7a")) {
        preferredArch = "armeabi-v7a";
      } else if (supportedAbis.contains("x86_64")) {
        preferredArch = "x86_64";
      }
    }

    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('.apk') && name.contains(preferredArch)) {
        return asset['browser_download_url'] as String?;
      }
    }

    // Fallback: any APK asset in release
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('.apk')) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
  }

  /// Displays the TV-friendly D-Pad update dialog
  static Future<void> showUpdateDialog(
    BuildContext context,
    Map<String, dynamic> releaseData, {
    bool showSkipVersion = false,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _OtaUpdateDialog(
        releaseData: releaseData,
        showSkipVersion: showSkipVersion,
      ),
    );
  }

  static Future<void> installApk(String filePath) async {
    await _deviceChannel.invokeMethod('installApk', {'filePath': filePath});
  }

  static bool _isRemoteNewer(String current, String remote) {
    try {
      final cParts = current.split('.').map((p) => int.tryParse(p.split('+').first) ?? 0).toList();
      final rParts = remote.split('.').map((p) => int.tryParse(p.split('+').first) ?? 0).toList();
      for (int i = 0; i < 3; i++) {
        final c = i < cParts.length ? cParts[i] : 0;
        final r = i < rParts.length ? rParts[i] : 0;
        if (r > c) return true;
        if (r < c) return false;
      }
    } catch (_) {}
    return remote != current;
  }
}

class _OtaUpdateDialog extends StatefulWidget {
  final Map<String, dynamic> releaseData;
  final bool showSkipVersion;
  const _OtaUpdateDialog({required this.releaseData, this.showSkipVersion = false});

  @override
  State<_OtaUpdateDialog> createState() => _OtaUpdateDialogState();
}

class _OtaUpdateDialogState extends State<_OtaUpdateDialog> {
  bool _downloading = false;
  double _progress = 0.0;
  String _status = "A new update is available for Plezy.";

  Future<void> _startDownloadAndInstall() async {
    setState(() {
      _downloading = true;
      _status = "Connecting to GitHub release server...";
      _progress = 0.0;
    });

    try {
      final downloadUrl = await ForkOtaUpdateService.getDownloadUrlForDevice(widget.releaseData);
      if (downloadUrl == null) {
        setState(() {
          _downloading = false;
          _status = "No compatible APK found for your device architecture.";
        });
        return;
      }

      final client = http.Client();
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await client.send(request);

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;

      final cacheDir = await getTemporaryDirectory();
      final apkFile = File('${cacheDir.path}/plezy_update.apk');
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      final sink = apkFile.openWrite();

      await response.stream.listen((chunk) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && mounted) {
          setState(() {
            _progress = receivedBytes / totalBytes;
            _status = "Downloading update: ${(_progress * 100).toStringAsFixed(1)}%";
          });
        }
      }).asFuture();

      await sink.close();
      client.close();

      if (!mounted) return;
      setState(() => _status = "Download complete. Launching Android package installer...");

      await ForkOtaUpdateService.installApk(apkFile.path);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _status = "Update failed: $e";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final latestVersion = (widget.releaseData['latestVersion'] as String?) ??
        (widget.releaseData['tag_name'] as String?)?.replaceFirst('v', '') ??
        'New Version';
    final tagName = widget.releaseData['tag_name'] ?? 'v$latestVersion';
    final currentVersion = widget.releaseData['currentVersion'] as String?;

    return AlertDialog(
      backgroundColor: const Color(0xFF162234),
      title: Row(
        children: [
          const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Update Plezy ($tagName)",
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (currentVersion != null) ...[
              const SizedBox(height: 6),
              Text(
                "Installed: v$currentVersion  →  Available: v$latestVersion",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: Colors.white12,
                color: const Color(0xFF38BDF8),
                minHeight: 8,
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading)
          TextButton(
            autofocus: false,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Later", style: TextStyle(color: Colors.white60)),
          ),
        if (!_downloading && widget.showSkipVersion)
          TextButton(
            autofocus: false,
            onPressed: () async {
              await UpdateService.skipVersion(latestVersion);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text("Skip Version", style: TextStyle(color: Colors.white60)),
          ),
        ElevatedButton(
          autofocus: true,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF38BDF8),
            foregroundColor: const Color(0xFF0B132B),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          onPressed: _downloading ? null : _startDownloadAndInstall,
          child: Text(
            _downloading ? "Downloading..." : "Update Now",
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
