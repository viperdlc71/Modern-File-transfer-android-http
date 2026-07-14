import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persisted user preferences for LocalDrop.
class AppSettings {
  final String folderPath;
  final bool regeneratePin;
  final String? fixedPin;
  final int port;

  const AppSettings({
    required this.folderPath,
    this.regeneratePin = true,
    this.fixedPin,
    this.port = 8080,
  });

  factory AppSettings.fromJson(Map<String, dynamic> m) => AppSettings(
        folderPath: m['folderPath'] as String,
        regeneratePin: m['regeneratePin'] as bool? ?? true,
        fixedPin: m['fixedPin'] as String?,
        port: m['port'] as int? ?? 8080,
      );

  AppSettings copyWith({
    String? folderPath,
    bool? regeneratePin,
    String? fixedPin,
    int? port,
  }) =>
      AppSettings(
        folderPath: folderPath ?? this.folderPath,
        regeneratePin: regeneratePin ?? this.regeneratePin,
        fixedPin: fixedPin ?? this.fixedPin,
        port: port ?? this.port,
      );

  Map<String, dynamic> toJson() => {
        'folderPath': folderPath,
        'regeneratePin': regeneratePin,
        'fixedPin': fixedPin,
        'port': port,
      };
}

/// Loads/saves [AppSettings] to a small JSON file in the app support dir.
class SettingsStore {
  static const String _fileName = 'localdrop_settings.json';

  Future<String> get _filePath async =>
      p.join((await getApplicationSupportDirectory()).path, _fileName);

  Future<AppSettings> load() async {
    try {
      final file = File(await _filePath);
      if (await file.exists()) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return AppSettings.fromJson(json);
      }
    } catch (_) {
      // fall through to defaults
    }
    return AppSettings(folderPath: await defaultSharedFolder());
  }

  Future<void> save(AppSettings settings) async {
    final file = File(await _filePath);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

/// A sensible default: an app-owned `LocalDrop` folder. On Android 11+ this is
/// readable/writable by the app without broad storage permissions; the user can
/// later point the share at any SAF-selected folder.
Future<String> defaultSharedFolder() async {
  Directory? base;
  if (Platform.isAndroid) {
    base = await getExternalStorageDirectory();
  }
  base ??= await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'LocalDrop'));
  await dir.create(recursive: true);
  return dir.path;
}

/// Opens Android's Storage Access Framework folder picker.
Future<String?> pickSharedFolder() async {
  return FilePicker.platform.getDirectoryPath(
    dialogTitle: 'Choose the folder to share',
  );
}

/// Ensures the folder exists and is read/writable; returns false otherwise.
Future<bool> ensureFolder(String path) async {
  try {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Probe both read and write access with a throwaway file.
    final probe = File(p.join(path, '.localdrop_probe'));
    await probe.writeAsBytes([0]);
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}
