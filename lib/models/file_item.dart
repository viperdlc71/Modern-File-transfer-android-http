import 'dart:convert';

class FileItem {
  final String name;
  final int size;
  final int modifiedSeconds;
  final String type;

  const FileItem({
    required this.name,
    required this.size,
    required this.modifiedSeconds,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'modified': modifiedSeconds,
        'type': type,
      };

  factory FileItem.fromJson(Map<String, dynamic> m) => FileItem(
        name: m['name'] as String,
        size: m['size'] as int,
        modifiedSeconds: m['modified'] as int,
        type: (m['type'] as String?) ?? '',
      );
}

String encodeFileItems(List<FileItem> items) =>
    jsonEncode({'files': items.map((f) => f.toJson()).toList()});
