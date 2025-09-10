import 'package:flutter/material.dart';
import 'dart:io';
import 'package:ciphercopy/ciphercopy_steps.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const initialSize = Size(500, 800);
    await windowManager.waitUntilReadyToShow().then((_) async {
      await windowManager.setTitle('CiPHERCOPY');
      await windowManager.setMinimumSize(const Size(500, 600));
      await windowManager.setSize(initialSize);
      await windowManager.show();
      await windowManager.setPreventClose(false);
    });
  }
  runApp(const CipherCopyApp());
}

class CipherCopyApp extends StatelessWidget {
  const CipherCopyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CiPHERCOPY',
      theme: ThemeData(primarySwatch: Colors.lightGreen),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.system,
      home: const CipherCopySteps(),
    );
  }
}
