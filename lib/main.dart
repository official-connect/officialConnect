import 'package:flutter/material.dart';
import 'dart:async';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/login_screen.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:provider/provider.dart';
import 'Screens/loading_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:official_connect/Services/firebase_operations.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:shared_preferences/shared_preferences.dart';

// to build web app
// flutter build web --web-renderer canvaskit --no-sound-null-safety --release

// to build flutter apk:
// flutter build apk --split-per-abi
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((
      _,
    ) {
      runApp(const MyApp());
    });
  } else {
    runApp(const MyApp());
  }
  unawaited(_initializeOperations());
}

Future<void> _initializeOperations() async {
  final prefs = await SharedPreferences.getInstance();
  final diagnosticsEnabled = prefs.getBool('diagnosticsEnabled') ?? true;
  await SyncDiagnostics.setEnabled(diagnosticsEnabled);
  await FirebaseOperations.initialize(enabled: diagnosticsEnabled);
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      FirebaseFeatureFlags.refreshInBackground();
    }
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [ChangeNotifierProvider(create: (ctx) => SisData())],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // Screens adapt to the actual logical viewport. Scaling a minimum
        // 480px canvas down on phones also shrinks navigation and tap targets.
        title: 'Connect',
        theme: ThemeData(primarySwatch: Colors.blue),
        // home: Unified(),
        home: const LoadingScreen(),
        routes: {
          LoginScreen.id: (context) => const LoginScreen(),
          Unified.id: (context) => const Unified(),
        },
      ),
    );
  }
}
