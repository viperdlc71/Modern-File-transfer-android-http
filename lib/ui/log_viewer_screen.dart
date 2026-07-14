import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppController>().fetchLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Server Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => controller.fetchLogs(),
          ),
        ],
      ),
      body: controller.logs.isEmpty
          ? Center(
              child: Text(
                'No logs yet. Start the server to generate logs.',
                style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: controller.logs.length,
              itemBuilder: (context, index) {
                final entry = controller.logs[index];
                final isError = entry.toLowerCase().contains('error') ||
                    entry.toLowerCase().contains('failed') ||
                    entry.toLowerCase().contains('aborted');
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isError
                        ? scheme.errorContainer.withOpacity(0.5)
                        : scheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isError ? scheme.error.withOpacity(0.3) : scheme.outline.withOpacity(0.2),
                    ),
                  ),
                  child: Text(
                    entry,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isError ? scheme.onErrorContainer : scheme.onSurface,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
