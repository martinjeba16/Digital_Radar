import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'providers/radar_preferences_provider.dart';
import 'services/app_navigator.dart';
import 'services/fcm_service.dart';
import 'services/notification_service.dart';
import 'services/radar_foreground_service.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FATAL: ${details.exception}\n${details.stack}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PLATFORM ERROR: $error\n$stack');
    return true;
  };

  await RadarForegroundService.init();

  var firebaseReady = false;
  for (var attempt = 0; attempt < 3 && !firebaseReady; attempt++) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      firebaseReady = true;
    } catch (e) {
      debugPrint('Firebase init attempt ${attempt + 1} failed: $e');
      if (attempt < 2) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  await NotificationService.init();

  if (firebaseReady) {
    FcmService.markFirebaseReady();
    try {
      await FcmService.init();
      await FcmService.verifyAndLogToken();
    } catch (e) {
      debugPrint('FCM init skipped: $e');
    }
  }

  final prefsProvider = RadarPreferencesProvider();
  await prefsProvider.init();
  // Let notification action handlers update the in-memory ledger / bookmarks.
  NotificationService.preferences = prefsProvider;

  runApp(
    ChangeNotifierProvider.value(
      value: prefsProvider,
      child: const DigitalRadarApp(),
    ),
  );
}

class DigitalRadarApp extends StatelessWidget {
  const DigitalRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<RadarPreferencesProvider>(
      builder: (context, prefs, _) {
        return MaterialApp(
          navigatorKey: AppNavigator.key,
          title: 'Digital Radar',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF1565C0),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF1565C0),
              brightness: Brightness.dark,
              surface: const Color(0xFF0D0D0D),
            ),
            scaffoldBackgroundColor: const Color(0xFF0D0D0D),
            useMaterial3: true,
          ),
          themeMode: prefs.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: WithForegroundTask(child: const HomeScreen()),
        );
      },
    );
  }
}
