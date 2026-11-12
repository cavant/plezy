import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/home_assistant_sync_service.dart';
import '../services/settings_service.dart';
import '../services/shield_optimization_service.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'focusable_list_tile.dart';
import 'setting_tile.dart';
import 'settings_section.dart';

/// Self-contained settings section for NVIDIA Shield TV optimizations and
/// Home Assistant webhook integration.
///
/// Kept in a dedicated file so upstream changes to settings screens only ever
/// touch a single widget reference line.
class ShieldCustomSettingsSection extends StatelessWidget {
  const ShieldCustomSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: 'NVIDIA Shield TV & Hardware Tuning',
          children: [
            ListenableBuilder(
              listenable: settings.listenableOf(SettingsService.shieldOptimizationEnabled),
              builder: (context, _) {
                final enabled = settings.read(SettingsService.shieldOptimizationEnabled);
                return FocusableSwitchListTile(
                  secondary: const AppIcon(Symbols.memory_rounded, fill: 1),
                  title: const Text('NVIDIA Shield TV Optimizations'),
                  subtitle: const Text(
                    'Applies 4K DoVi/HDR10 frame-queue limits, 0.5x OSD plane, 48MB Skia cap, shader bypass & auto RAM trimmer',
                  ),
                  value: enabled,
                  onChanged: (next) async {
                    await ShieldOptimizationService.instance.setEnabled(settings, next);
                    if (context.mounted) {
                      showAppSnackBar(
                        context,
                        next
                            ? 'NVIDIA Shield TV optimizations enabled & applied'
                            : 'NVIDIA Shield TV optimizations disabled (defaults restored)',
                      );
                    }
                  },
                );
              },
            ),
            FocusableListTile(
              leading: const AppIcon(Symbols.cleaning_services_rounded, fill: 1),
              title: const Text('Trim Background Memory Now'),
              subtitle: const Text('Reclaim RAM from inactive background streaming apps'),
              trailing: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
              onTap: () async {
                final report = await ShieldOptimizationService.instance.trimBackgroundMemory();
                if (context.mounted) {
                  if (report != null && report['success'] == true) {
                    final freedMb = ((report['freedBytes'] as int? ?? 0) / (1024 * 1024)).round();
                    final availMb = ((report['availMem'] as int? ?? 0) / (1024 * 1024)).round();
                    final killed = report['killedCount'] as int? ?? 0;
                    showAppSnackBar(
                      context,
                      'Trimmed $killed background apps (Freed ~${freedMb}MB, Avail: ${availMb}MB)',
                    );
                  } else {
                    showErrorSnackBar(context, 'Background memory trim unavailable on this platform');
                  }
                }
              },
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
              subtitle: 'Zero-latency play/pause/stop sync for smart lighting and soundbar automations',
            ),
            ListenableBuilder(
              listenable: settings.listenableOf(SettingsService.homeAssistantWebhookUrl),
              builder: (context, _) {
                final currentUrl = settings.read(SettingsService.homeAssistantWebhookUrl);
                return FocusableListTile(
                  leading: const AppIcon(Symbols.link_rounded, fill: 1),
                  title: const Text('Webhook URL'),
                  subtitle: Text(
                    currentUrl.isNotEmpty
                        ? currentUrl
                        : 'HTTP endpoint for Home Assistant automation trigger',
                  ),
                  trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                  onTap: () => _showWebhookUrlDialog(context, settings, currentUrl),
                );
              },
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
      ],
    );
  }

  Future<void> _showWebhookUrlDialog(
    BuildContext context,
    SettingsService settings,
    String currentValue,
  ) async {
    const defaultUrl = 'http://192.168.1.114/api/webhook/plezy_playback';
    final controller = TextEditingController(text: currentValue);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Webhook URL'),
          content: SizedBox(
            width: 440,
            child: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Home Assistant Webhook URL',
                hintText: defaultUrl,
              ),
              onSubmitted: (value) async {
                final trimmed = value.trim();
                await settings.write(
                  SettingsService.homeAssistantWebhookUrl,
                  trimmed.isEmpty ? defaultUrl : trimmed,
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.text = defaultUrl;
              },
              child: const Text('Reset to Default'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final trimmed = controller.text.trim();
                await settings.write(
                  SettingsService.homeAssistantWebhookUrl,
                  trimmed.isEmpty ? defaultUrl : trimmed,
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }
}
