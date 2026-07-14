import 'package:flutter/material.dart';

import '../models/transfer.dart';

class TransferList extends StatelessWidget {
  final List<Transfer> transfers;
  const TransferList({super.key, required this.transfers});

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) return const SizedBox.shrink();
    final active =
        transfers.where((t) => !t.done && !t.failed).toList();
    final recent = transfers.where((t) => t.done || t.failed).toList();
    final visible = [...active, ...recent.take(3)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transfers',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        ...visible.map((t) => _TransferTile(transfer: t)),
      ],
    );
  }
}

class _TransferTile extends StatelessWidget {
  final Transfer transfer;
  const _TransferTile({required this.transfer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUpload = transfer.direction == TransferDirection.upload;
    final icon = isUpload ? Icons.upload_rounded : Icons.download_rounded;
    final fraction = transfer.fraction;
    final pct = fraction < 0 ? null : (fraction * 100).round();

    final subtitle = transfer.failed
        ? (transfer.error ?? 'Failed')
        : transfer.done
            ? 'Done · ${_formatBytes(transfer.transferredBytes)}'
            : pct == null
                ? '${_formatBytes(transfer.transferredBytes)} · ${_formatSpeed(transfer.speedBytesPerSec)}'
                : '$pct% · ${_formatSpeed(transfer.speedBytesPerSec)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (transfer.done && !transfer.failed)
                  const Icon(Icons.check_circle_outline,
                      size: 18, color: Colors.green)
                else if (transfer.failed)
                  Icon(Icons.error_outline,
                      size: 18, color: scheme.error),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (!transfer.done && !transfer.failed)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: fraction < 0 ? 1 : fraction),
                duration: const Duration(milliseconds: 200),
                builder: (_, value, __) => LinearProgressIndicator(
                  value: fraction < 0 ? null : value,
                  borderRadius: BorderRadius.circular(6),
                ),
              )
            else if (transfer.failed)
              LinearProgressIndicator(
                value: 1,
                color: scheme.error,
                borderRadius: BorderRadius.circular(6),
              )
            else
              LinearProgressIndicator(
                value: 1,
                color: Colors.green,
                borderRadius: BorderRadius.circular(6),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${i == 0 ? v.round() : v.toStringAsFixed(1)} ${units[i]}';
}

String _formatSpeed(double bytesPerSec) {
  if (bytesPerSec <= 0) return '0 MB/s';
  return '${_formatBytes(bytesPerSec.toInt())}/s';
}
