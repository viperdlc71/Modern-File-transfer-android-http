import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../server/local_server.dart';
import '../server/session_manager.dart';

/// Key under which the server config is stashed for the foreground-task isolate
/// to read on start (the isolate cannot share memory with the UI isolate).
const String kConfigKey = 'localdrop_config';

/// Immutable description of how to boot the embedded server, passed from the
/// UI isolate to the foreground-service isolate.
class ServerConfig {
  final String pin;
  final int port;
  final String folder;
  final bool regeneratePin;
  final List<String>? urls;

  const ServerConfig({
    required this.pin,
    required this.port,
    required this.folder,
    this.regeneratePin = true,
    this.urls,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> m) => ServerConfig(
        pin: m['pin'] as String,
        port: m['port'] as int,
        folder: m['folder'] as String,
        regeneratePin: m['regeneratePin'] as bool? ?? true,
        urls: m['urls'] != null ? List<String>.from(m['urls']) : null,
      );

  Map<String, dynamic> toJson() => {
        'pin': pin,
        'port': port,
        'folder': folder,
        'regeneratePin': regeneratePin,
        'urls': urls,
      };
}

/// Top-level entry point for the foreground service. Must be top-level (or
/// static) and annotated so the VM keeps it as an entry point.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_LocalDropTaskHandler());
}

class _LocalDropTaskHandler extends TaskHandler {
  LocalServer? _server;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final raw = await FlutterForegroundTask.getData(key: kConfigKey);
    if (raw == null) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': 'Missing server configuration.',
      });
      return;
    }
    final config = ServerConfig.fromJson(
      jsonDecode(raw as String) as Map<String, dynamic>,
    );

    final session = SessionManager(config.pin);
    _server = LocalServer(
      sessionManager: session,
      sharedFolder: config.folder,
      onEvent: (event) => FlutterForegroundTask.sendDataToMain(event),
    );

    try {
      final port = await _server!.start(preferredPort: config.port);
      FlutterForegroundTask.updateService(
        notificationTitle: 'LocalDrop is sharing files',
        notificationText: '${(config.urls ?? ['http://localhost:$port']).join(' / ')}  ·  PIN ${config.pin}',
      );
      FlutterForegroundTask.sendDataToMain({
        'type': 'started',
        'port': port,
        'pin': config.pin,
      });
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': 'Could not start server: $e',
      });
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Lightweight heartbeat: keep the notification current with live transfer
    // activity so the user can glance at progress from the lock screen.
    final transfers = _server?.transferManager.snapshot() ?? [];
    final active = transfers.where((t) => !t.done && !t.failed).length;
    if (active > 0) {
      FlutterForegroundTask.updateService(
        notificationText: '$active transfer${active == 1 ? '' : 's'} in progress',
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _server?.stop();
    _server = null;
    FlutterForegroundTask.sendDataToMain({'type': 'stopped'});
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final map = data as Map;
    final type = map['type'];
    if (type == 'stop') {
      unawaited(_server?.stop());
      _server = null;
      FlutterForegroundTask.sendDataToMain({'type': 'stopped'});
    } else if (type == 'setFolder' && map['folder'] is String) {
      _server?.sharedFolder = map['folder'] as String;
      FlutterForegroundTask.sendDataToMain({
        'type': 'folder-changed',
        'folder': map['folder'],
      });
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      unawaited(_server?.stop());
      _server = null;
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}

/// Stores the config for the next service start and launches the service.
Future<ServiceRequestResult> startForegroundService(ServerConfig config) async {
  await FlutterForegroundTask.saveData(
    key: kConfigKey,
    value: jsonEncode(config.toJson()),
  );
  if (await FlutterForegroundTask.isRunningService) {
    return FlutterForegroundTask.restartService();
  }
  return FlutterForegroundTask.startService(
    serviceId: 256,
    notificationTitle: 'LocalDrop is sharing files',
    notificationText: '${(config.urls ?? ['']).join(' / ')}  ·  PIN ${config.pin}',
    notificationIcon: null,
    notificationButtons: const [
      NotificationButton(id: 'stop', text: 'Stop'),
    ],
    callback: startCallback,
  );
}

Future<ServiceRequestResult> stopForegroundService() async {
  return FlutterForegroundTask.stopService();
}

/// Ask the running service to change the shared folder at runtime.
void requestFolderChange(String folder) {
  FlutterForegroundTask.sendDataToTask({'type': 'setFolder', 'folder': folder});
}
