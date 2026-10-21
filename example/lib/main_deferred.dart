import 'package:flutter/material.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'examples/deferred.dart';

/// Dedicated entrypoint that lands straight on the deferred rendering
/// benchmark, for verifying the replay path without navigating the demo list.
/// Run with: flutter run -t lib/main_deferred.dart

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await rive.RiveNative.init();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF1D1D1D),
        body: ExampleDeferred(),
      ),
    ),
  );
}
