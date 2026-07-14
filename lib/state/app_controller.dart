import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/transfer.dart';
import '../server/session_manager.dart';
import '../services/foreground_service.dart';
import '../services/shared_folder.dart';

/// Central, framework-agnostic controller for LocalDrop's runtime state.
/// Exposed to the widget tree via a [ChangeNotifierProvider].
class AppController extends ChangeNotifier {
  final SettingsStore _store = SettingsStore();

  AppSettings _settings;
  bool _initialized = false;

  bool isRunning = false;
  bool isStarting = false;
  List<String> localIps = [];
  int? port;
  String? pin;
  List<String> urls = [];
  String? folder;
  String? error;
  bool permissionsGranted = false;
  bool storagePermissionAsked = false;
  bool storagePermissionGranted = false;

  List<Transfer> transfers = const [];
  List<String> logs = const [];

  AppController(this._settings);

  AppSettings get settings => _settings;

  /// Call once at startup (after [WidgetsFlutterBinding.ensureInitialized]).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _initForegroundTask();
    await _requestPermissions();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);

    final hasSettings = await _store.exists();
    if (hasSettings && _settings.folderPath.isNotEmpty) {
      final accessible = await ensureFolder(_settings.folderPath);
      storagePermissionGranted = accessible;
    }
    storagePermissionAsked = true;
    notifyListeners();

    // If a service is already running (e.g. survived app close), restore state
    // from the config we previously saved for the task isolate.
    if (await FlutterForegroundTask.isRunningService) {
      try {
        final raw = await FlutterForegroundTask.getData(key: kConfigKey);
        if (raw != null) {
          final decoded = raw is String ? jsonDecode(raw) : raw;
          final cfg = ServerConfig.fromJson(decoded as Map<String, dynamic>);
          isRunning = true;
          pin = cfg.pin;
          port = cfg.port;
          folder = cfg.folder;
          urls = cfg.urls ?? [];
        }
      } catch (_) {
        // ignore — treat as not running
      }
    }
    notifyListeners();
  }
    storagePermissionAsked = true;
    notifyListeners();

    // If a service is already running (e.g. survived app close), restore state
    // from the config we previously saved for the task isolate.
    if (await FlutterForegroundTask.isRunningService) {
      try {
        final raw = await FlutterForegroundTask.getData(key: kConfigKey);
        if (raw != null) {
          final decoded = raw is String ? jsonDecode(raw) : raw;
          final cfg = ServerConfig.fromJson(decoded as Map<String, dynamic>);
          isRunning = true;
          pin = cfg.pin;
          port = cfg.port;
          folder = cfg.folder;
          urls = cfg.urls ?? [];
        }
      } catch (_) {
        // ignore — treat as not running
      }
    }
    notifyListeners();
  }

  Future<void> _requestPermissions() async {
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (Platform.isAndroid) {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      }
      permissionsGranted = true;
    } catch (_) {
      permissionsGranted = false;
    }
    notifyListeners();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'localdrop_foreground',
        channelName: 'LocalDrop File Sharing',
        channelDescription: 'Keeps the local file-sharing server alive.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts the embedded server (via the foreground service).
  Future<void> start() async {
    if (isRunning || isStarting) return;
    isStarting = true;
    error = null;
    notifyListeners();

    final ips = await _resolveLocalIps();
    localIps = ips;

    final effectivePin = _settings.regeneratePin
        ? SessionManager.generatePin()
        : (_settings.fixedPin ?? SessionManager.generatePin());

    // Persist a freshly chosen fixed PIN so it stays stable across restarts.
    if (!_settings.regeneratePin && _settings.fixedPin != effectivePin) {
      _settings = _settings.copyWith(fixedPin: effectivePin);
      await _store.save(_settings);
    }

    final usableFolder = _settings.folderPath;
    final accessible = await ensureFolder(usableFolder);
    if (!accessible) {
      isStarting = false;
      error = 'Cannot access the shared folder:\n$usableFolder';
      notifyListeners();
      return;
    }
    folder = usableFolder;

    pin = effectivePin;
    port = _settings.port;
    urls = ips.map((ip) => 'http://$ip:${_settings.port}').toList();

    final config = ServerConfig(
      pin: effectivePin,
      port: _settings.port,
      folder: usableFolder,
      regeneratePin: _settings.regeneratePin,
      urls: urls,
    );

    try {
      await startForegroundService(config);
    } catch (e) {
      isStarting = false;
      error = 'Failed to start: $e';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!isRunning && !isStarting) return;
    try {
      await stopForegroundService();
    } catch (_) {
      // ignore
    }
    isRunning = false;
    isStarting = false;
    notifyListeners();
  }

  Future<void> changeFolder() async {
    final picked = await pickSharedFolder();
    if (picked == null || picked == folder) return;
    _settings = _settings.copyWith(folderPath: picked);
    await _store.save(_settings);
    folder = picked;
    if (isRunning) {
      requestFolderChange(picked);
    }
    notifyListeners();
  }

  Future<bool> requestStoragePermission() async {
    final picked = await pickSharedFolder();
    if (picked == null) return false;
    final accessible = await ensureFolder(picked);
    if (!accessible) return false;
    _settings = _settings.copyWith(folderPath: picked);
    await _store.save(_settings);
    folder = picked;
    storagePermissionGranted = true;
    notifyListeners();
    return true;
  }

  Future<void> updateSettings({
    bool? regeneratePin,
    int? port,
  }) async {
    _settings = _settings.copyWith(
      regeneratePin: regeneratePin,
      port: port,
    );
    await _store.save(_settings);
    notifyListeners();
  }

  Future<void> fetchLogs() async {
    if (!isRunning || port == null) return;
    try {
      final uri = Uri.parse('http://127.0.0.1:${port!}/api/logs');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer ${_getCurrentToken()}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (response.statusCode == 200) {
        logs = body.split('\n').where((l) => l.isNotEmpty).toList();
        notifyListeners();
      }
    } catch (_) {
      // ignore log fetch errors
    }
  }

  String? _getCurrentToken() {
    // Token is managed by the foreground service; we don't expose it directly.
    // For localhost log fetches, the service accepts requests without auth if
    // they come from the device itself. This is a convenience shortcut.
    return null;
  }

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final map = data;
    switch (map['type']) {
      case 'started':
        isRunning = true;
        isStarting = false;
        port = map['port'] as int? ?? port;
        pin = map['pin'] as String? ?? pin;
        error = null;
      case 'error':
        isRunning = false;
        isStarting = false;
        error = map['message'] as String? ?? 'Unknown error';
      case 'stopped':
        isRunning = false;
        isStarting = false;
        transfers = const [];
      case 'folder-changed':
        folder = map['folder'] as String? ?? folder;
      case 'progress':
        final raw = map['transfers'];
        if (raw is String) {
          transfers = decodeTransfers(raw);
        }
    }
    notifyListeners();
  }

  Future<List<String>> _resolveLocalIps() async {
    final ips = <String>[];
    try {
      final wifi = await NetworkInfo().getWifiIP();
      if (wifi != null && wifi.isNotEmpty && !ips.contains(wifi)) {
        ips.add(wifi);
      }
    } catch (_) {
      // fall through to interface scan
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final s = addr.address;
          if (!ips.contains(s)) ips.add(s);
        }
      }
    } catch (_) {
      // ignore
    }
    if (ips.isEmpty) ips.add('127.0.0.1');
    return ips;
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }
}

/// Convenience accessor for widgets.
AppController appControllerOf(BuildContext context) =>
    Provider.of<AppController>(context, listen: false);
