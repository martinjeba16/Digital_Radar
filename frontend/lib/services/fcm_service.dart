import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'location_ping_logic.dart';
import 'notification_service.dart';

/// Top-level background handler required by firebase_messaging.
/// Must be a top-level or static function (not a closure).
///
/// Receives data-only FCM payloads and builds a rich local notification
/// with BigPicture style and action buttons.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final data = message.data;
  if (data.isEmpty) return;

  final title = data['title'] ?? 'Digital Radar';
  final body = data['body'] ?? '';
  final expandedSummary = data['expanded_summary'] ?? '';
  final imageUrl = data['image_url'];
  final locationId = data['location_id'] ?? '';
  final lat = data['lat'] ?? '';
  final lon = data['lon'] ?? '';
  final poiLat = data['poi_lat'] ?? '';
  final poiLon = data['poi_lon'] ?? '';
  final category = data['category'] ?? 'nearby';
  final deviceToken = await LocationPingLogic.getDeviceToken();

  debugPrint(
    'FCM background: title=$title imageUrl=${imageUrl ?? "NULL"} '
    'locationId=$locationId keys=${data.keys.toList()}',
  );

  await NotificationService.showRich(
    title: title,
    body: body,
    expandedSummary: expandedSummary,
    imageUrl: imageUrl,
    locationId: locationId,
    lat: lat,
    lon: lon,
    poiLat: poiLat,
    poiLon: poiLon,
    deviceToken: deviceToken,
    category: category,
  );
}

/// Wraps Firebase Cloud Messaging: permission, token retrieval, foreground
/// message display, and data-only notification rendering.
class FcmService {
  static bool _firebaseReady = false;
  static FirebaseMessaging? _messaging;
  static String? _lastToken;

  /// Call only after [Firebase.initializeApp] succeeds.
  static void markFirebaseReady() {
    _firebaseReady = true;
    _messaging = FirebaseMessaging.instance;
  }

  static bool get isAvailable => _firebaseReady && _messaging != null;

  /// Last successfully retrieved FCM token (full value, for ping payloads).
  static String? get lastToken => _lastToken;

  /// Short prefix safe to show in debug UI / logs.
  static String? get tokenPreview =>
      _lastToken == null ? null : '${_lastToken!.substring(0, 12)}…';

  static Future<void> init() async {
    if (!isAvailable) return;

    await _messaging!.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);

    // Foreground messages — same data-only treatment.
    FirebaseMessaging.onMessage.listen((message) async {
      final data = message.data;
      if (data.isEmpty) return;

      final title = data['title'] ?? 'Digital Radar';
      final body = data['body'] ?? '';
      final expandedSummary = data['expanded_summary'] ?? '';
      final imageUrl = data['image_url'];
      final locationId = data['location_id'] ?? '';
      final lat = data['lat'] ?? '';
      final lon = data['lon'] ?? '';
      final poiLat = data['poi_lat'] ?? '';
      final poiLon = data['poi_lon'] ?? '';

      final category = data['category'] ?? 'nearby';

      debugPrint(
        'FCM foreground: title=$title imageUrl=${imageUrl ?? "NULL"} '
        'keys=${data.keys.toList()}',
      );

      final token = _lastToken ?? await LocationPingLogic.getDeviceToken();
      await NotificationService.showRich(
        title: title,
        body: body,
        expandedSummary: expandedSummary,
        imageUrl: imageUrl,
        locationId: locationId,
        lat: lat,
        lon: lon,
        poiLat: poiLat,
        poiLon: poiLon,
        deviceToken: token,
        category: category,
      );
    });

    await verifyAndLogToken();

    _messaging!.onTokenRefresh.listen((token) async {
      await _persistToken(token, source: 'token refresh');
    });
  }

  /// Fetch the current token, persist it, and print a diagnostic line.
  /// Call on startup and when troubleshooting push delivery.
  static Future<String?> verifyAndLogToken() async {
    final token = await currentToken();
    if (token == null) {
      debugPrint('FCM TOKEN: null — push notifications will NOT work');
      return null;
    }

    if (!isValidToken(token)) {
      debugPrint(
        'FCM TOKEN: INVALID (looks like a placeholder): $token',
      );
      return null;
    }

    debugPrint('FCM TOKEN preview: ${token.substring(0, 12)}… (${token.length} chars)');
    return token;
  }

  /// The FCM registration token identifying this device to the backend.
  static Future<String?> currentToken() async {
    if (!isAvailable) return null;
    try {
      final token = await _messaging!.getToken();
      if (token != null) {
        await _persistToken(token, source: 'getToken');
      }
      return token;
    } catch (e) {
      debugPrint('FCM getToken failed: $e');
      return null;
    }
  }

  /// True when [token] looks like a real Firebase registration token.
  static bool isValidToken(String? token) {
    if (token == null || token.isEmpty) return false;

    const placeholders = {
      'dev-local-token',
      'YOUR_FCM_TOKEN_FROM_APP',
      'YOUR_FCM_TOKEN',
      'YOUR_FCM_TOK',
      'fcm_token_abc123',
    };
    if (placeholders.contains(token)) return false;
    if (token.startsWith('YOUR_FCM')) return false;

    // Real FCM tokens are long opaque strings from Google.
    return token.length >= 80;
  }

  static Future<void> _persistToken(String token, {required String source}) async {
    _lastToken = token;
    await LocationPingLogic.saveDeviceToken(token);
    debugPrint(
      'FCM token saved ($source): ${token.substring(0, 12)}… (${token.length} chars)',
    );
  }

  /// Notifies a callback whenever the token is refreshed by FCM.
  static Stream<String> get onTokenRefresh {
    if (!isAvailable) return const Stream.empty();
    return _messaging!.onTokenRefresh;
  }
}
