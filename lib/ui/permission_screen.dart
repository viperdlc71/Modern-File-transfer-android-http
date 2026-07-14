import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';

class PermissionScreen extends StatelessWidget {
  const PermissionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 80,
                color: scheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'Choose a folder to share',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'LocalDrop needs access to a folder on your device. '
                'Files in that folder will be available for download, '
                'and uploads will be saved there.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withOpacity(0.7),
                    ),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () async {
                  final ok = await controller.requestStoragePermission();
                  if (!ok && context.mounted) {
                    _showDeniedDialog(context);
                  }
                },
                icon: const Icon(Icons.folder_rounded),
                label: const Text('Select folder'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  _openAppSettings();
                },
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Open app settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeniedDialog(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: scheme.tertiary, size: 40),
        title: const Text('Permission required'),
        content: const Text(
          'Please select a folder to continue. '
          'If the picker does not appear, open app settings and grant storage access.',
        ),
        actions: [
          TextButton(
            onPressed: () => _openAppSettings(),
            child: const Text('Open settings'),
          ),
          FilledButton(
            onPressed: () async {
              // ignore: use_build_context_synchronously
              Navigator.of(context).pop();
            },
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  void _openAppSettings() {
    // In a real app you'd use: await openAppSettings();
    // For now we rely on the user manually granting via the picker.
  }
}
