import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transfer.dart';
import '../state/app_controller.dart';
import 'settings_screen.dart';
import 'transfer_list.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalDrop'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.error != null) _ErrorBanner(error: controller.error!),
          if (!controller.isRunning && !controller.isStarting)
            _StartPanel(controller: controller)
          else
            _RunningPanel(controller: controller),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String error;
  const _ErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _StartPanel extends StatelessWidget {
  final AppController controller;
  const _StartPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 24),
        Icon(
          Icons.router_outlined,
          size: 72,
          color: scheme.primary.withOpacity(0.8),
        ),
        const SizedBox(height: 16),
        Text(
          'Turn your phone into a\nlocal file hub',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Start the server, then open the shown URL on any device '
          'on the same network — no app install needed.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withOpacity(0.7),
              ),
        ),
        if (!controller.permissionsGranted) ...[
          const SizedBox(height: 12),
          Text(
            'Tip: grant notification permission so the server can run in the '
            'background.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: controller.start,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start Server'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            textStyle: const TextStyle(fontSize: 18),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _RunningPanel extends StatelessWidget {
  final AppController controller;
  const _RunningPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PulsingCard(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.surfaceVariant,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.circle, size: 10, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      controller.isStarting ? 'Starting…' : 'Server is live',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (controller.urls.isNotEmpty)
                  ...controller.urls.map((url) => Column(
                        children: [
                          QrImageView(
                            data: url,
                            size: 180,
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.all(10),
                          ),
                          const SizedBox(height: 8),
                          const Text('Scan or open', style: TextStyle(fontSize: 11)),
                          const SizedBox(height: 4),
                          SelectableText(
                            url,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                      )),
                const SizedBox(height: 20),
                const Text('PIN', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    controller.pin ?? '------',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _FolderRow(controller: controller),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.tonalIcon(
          onPressed: controller.stop,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop Server'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 24),
        TransferList(transfers: controller.transfers),
      ],
    );
  }
}

class _FolderRow extends StatelessWidget {
  final AppController controller;
  const _FolderRow({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: controller.changeFolder,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Shared folder',
                        style: TextStyle(fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      controller.folder ?? '—',
                      style: const TextStyle(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: controller.changeFolder,
                child: const Text('Change'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulsingCard extends StatefulWidget {
  final Widget child;
  const _PulsingCard({required this.child});

  @override
  State<_PulsingCard> createState() => _PulsingCardState();
}

class _PulsingCardState extends State<_PulsingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  late final Animation<double> _glow =
      Tween<double>(begin: 0.15, end: 0.5).animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withOpacity(_glow.value),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
