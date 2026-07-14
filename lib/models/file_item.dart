import 'dart:convert';

class FileItem {
  final String name;
  final int size;
  final int modifiedSeconds;
  final String type;
  final bool isDirectory;
  final String path;

  const FileItem({
    required this.name,
    required this.size,
    required this.modifiedSeconds,
    required this.type,
    this.isDirectory = false,
    this.path = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'modified': modifiedSeconds,
        'type': type,
        'isDirectory': isDirectory,
        'path': path,
      };

  factory FileItem.fromJson(Map<String, dynamic> m) => FileItem(
        name: m['name'] as String,
        size: m['size'] as int,
        modifiedSeconds: m['modified'] as int,
        type: (m['type'] as String?) ?? '',
        isDirectory: m['isDirectory'] as bool? ?? false,
        path: (m['path'] as String?) ?? '',
      );
}

String encodeFileItems(List<FileItem> items) =>
    jsonEncode({'files': items.map((f) => f.toJson()).toList()});
