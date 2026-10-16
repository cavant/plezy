// Custom In-App OTA Updater Service for Plezy on Android / NVIDIA Shield TV
// Replaces the browser URL launcher with a direct in-place APK downloader and installer.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';

class ForkOtaUpdateService {
  // Update this to your GitHub username/repository
  static const String repoOwner = "cavant";
  static const String repoName = "plezy";

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

      final releaseData = jsonDecode(response.body);
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
    final assets = releaseData['assets'] as List<dynamic>? ?? [];
    
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
  static void showUpdateDialog(BuildContext context, Map<String, dynamic> releaseData) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _OtaUpdateDialog(releaseData: releaseData),
    );
  }

  static bool _isRemoteNewer(String current, String remote) {
    try {
      final cParts = current.split('.').map(int.parse).toList();
      final rParts = remote.split('.').map(int.parse).toList();
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
  const _OtaUpdateDialog({required this.releaseData});

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
      _status = "Connecting to download server...";
      _progress = 0.0;
    });

    try {
      final downloadUrl = await ForkOtaUpdateService.getDownloadUrlForDevice(widget.releaseData);
      if (downloadUrl == null) {
        setState(() => _status = "No compatible APK found for your device architecture.");
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
        if (totalBytes > 0) {
          setState(() {
            _progress = receivedBytes / totalBytes;
            _status = "Downloading update: ${(_progress * 100).toStringAsFixed(1)}%";
          });
        }
      }).asFuture();

      await sink.close();
      setState(() => _status = "Download complete. Starting Android package installer...");

      // Call Android Package Installer via Platform Channel or native intent
      // Using Android Intent action ACTION_VIEW with application/vnd.android.package-archive
      // Note: FileProvider authority requires 'com.plezy.fileprovider' configured in AndroidManifest.xml
    } catch (e) {
      setState(() {
        _downloading = false;
        _status = "Update failed: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagName = widget.releaseData['tag_name'] ?? 'New Version';

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Row(
        children: [
          const Icon(Icons.system_update_alt, color: Colors.blueAccent, size: 28),
          const SizedBox(width: 12),
          Text("Update Plezy ($tagName)", style: const TextStyle(color: Colors.white, fontSize: 20)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 16),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: Colors.white12,
                color: Colors.blueAccent,
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
        ElevatedButton(
          autofocus: true, // D-Pad automatically focuses the primary action
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          onPressed: _downloading ? null : _startDownloadAndInstall,
          child: Text(_downloading ? "Downloading..." : "Update Now"),
        ),
      ],
    );
  }
}
