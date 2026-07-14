import 'dart:convert';

enum TransferDirection { upload, download }

class Transfer {
  final String id;
  final String fileName;
  final TransferDirection direction;
  final int? totalBytes;
  int transferredBytes;
  double speedBytesPerSec;
  final DateTime createdAt;
  bool done;
  bool failed;
  String? error;

  Transfer({
    required this.id,
    required this.fileName,
    required this.direction,
    this.totalBytes,
    this.transferredBytes = 0,
    this.speedBytesPerSec = 0,
    DateTime? createdAt,
    this.done = false,
    this.failed = false,
    this.error,
  }) : createdAt = createdAt ?? DateTime.now();

  double get fraction {
    if (totalBytes == null || totalBytes == 0) return -1;
    return (transferredBytes / totalBytes!).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'direction': direction == TransferDirection.upload ? 'upload' : 'download',
        'totalBytes': totalBytes,
        'transferredBytes': transferredBytes,
        'speedBytesPerSec': speedBytesPerSec.round(),
        'done': done,
        'failed': failed,
        'error': error,
      };

  factory Transfer.fromJson(Map<String, dynamic> m) => Transfer(
        id: m['id'] as String,
        fileName: m['fileName'] as String,
        direction: m['direction'] == 'upload'
            ? TransferDirection.upload
            : TransferDirection.download,
        totalBytes: m['totalBytes'] as int?,
        transferredBytes: m['transferredBytes'] as int? ?? 0,
        speedBytesPerSec: (m['speedBytesPerSec'] as int? ?? 0).toDouble(),
        done: m['done'] as bool? ?? false,
        failed: m['failed'] as bool? ?? false,
        error: m['error'] as String?,
      );
}

String encodeTransfers(List<Transfer> list) =>
    jsonEncode(list.map((t) => t.toJson()).toList());

List<Transfer> decodeTransfers(String json) {
  final decoded = jsonDecode(json) as List<dynamic>;
  return decoded
      .map((e) => Transfer.fromJson(e as Map<String, dynamic>))
      .toList();
}
