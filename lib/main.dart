import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/shared_folder.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Required by flutter_foreground_task before the app starts.
  FlutterForegroundTask.initCommunicationPort();

  final store = SettingsStore();
  final settings = await store.load();
  final controller = AppController(settings);
  await controller.init();

  runApp(
    ChangeNotifierProvider.value(
      value: controller,
      child: const MyApp(),
    ),
  );
}
