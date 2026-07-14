import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import 'log_viewer_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Regenerate PIN each start'),
            subtitle: const Text(
              'When off, a fixed PIN is kept stable across restarts.',
            ),
            value: settings.regeneratePin,
            onChanged: (v) => controller.updateSettings(regeneratePin: v),
          ),
          if (!settings.regeneratePin && settings.fixedPin != null)
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Current fixed PIN'),
              trailing: Text(
                settings.fixedPin!,
                style: const TextStyle(
                  fontSize: 18,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Shared folder'),
            subtitle: Text(settings.folderPath),
            trailing: TextButton(
              onPressed: controller.changeFolder,
              child: const Text('Change'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.numbers_outlined),
            title: const Text('Port'),
            subtitle: const Text('Applied on next server start.'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                initialValue: settings.port.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed > 0 && parsed <= 65535) {
                    controller.updateSettings(port: parsed);
                  }
                },
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.terminal_rounded),
            title: const Text('Server logs'),
            subtitle: const Text('View recent server logs for debugging.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogViewerScreen()),
              );
            },
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Local network only. Transfers stay on your Wi-Fi — no relay, '
              'no internet. Set the port if 8080 is taken by another app.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
