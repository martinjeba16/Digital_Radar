import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/api_result.dart';
import '../models/discovery_item.dart';
import '../models/radar_ui_state.dart';
import 'api_service.dart';
import 'connectivity_service.dart';
import 'discovery_repository.dart';
import 'fcm_service.dart';

typedef PingProgressCallback = void Function(RadarUiState state);

  /// Shared location → ping logic used by foreground UI and background task.
class LocationPingLogic {
  /// Speed-to-radius buffer: at 100 km/h (28 m/s) this gives
  /// 28 × 120 = ~3.4 km extra radius beyond the user's baseline,
  /// providing ~2 minutes of pre-notification before crossing the POI.
  static const int _speedBufferSeconds = 120;
  static const int _maxRadiusM = 5000;
  static const prefLastLat = 'last_lat';
  static const prefLastLon = 'last_lon';
  static const prefDeviceToken = 'fcm_device_token';

  static Future<void> saveDeviceToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefDeviceToken, token);
  }

  static Future<String?> getDeviceToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefDeviceToken);
  }

  static const prefActiveVectors = 'active_vectors';

  // Shared SharedPreferences keys for display settings — written by
  // RadarPreferencesProvider (foreground UI) and read here so the ping
  // pipeline (including the background isolate, which has no BuildContext)
  // always sends the device's *current* Settings to the backend.
  static const prefRenderImages = 'pref_render_images';
  static const prefElaborateText = 'pref_elaborate_text';
  static const prefDarkMode = 'pref_dark_mode';
  static const prefRadiusHint = 'pref_radius_hint';
  static const prefNotificationsEnabled = 'pref_notifications_enabled';
  static const prefNotificationImages = 'pref_notification_images';
  static const prefNotificationFrequency = 'notification_frequency';

  static Future<Map<String, bool>?> _loadActiveVectors() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefActiveVectors);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as bool));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _loadRenderImages() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefRenderImages) ?? true;
  }

  static Future<bool> _loadElaborateText() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefElaborateText) ?? true;
  }

  static Future<String?> _loadRadiusHint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefRadiusHint);
  }

  static Future<String?> _loadNotificationFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefNotificationFrequency);
  }

  /// Returns a speed-adaptive radius (metres) when [speedMps] is available,
  /// or the user's static [radiusHint] baseline when speed is null / zero.
  ///
  /// At highway speeds (100 km/h ≈ 28 m/s) the result can reach ~4200 m,
  /// giving the driver ~2 minutes of pre-notification before reaching a POI.
  /// The result is clamped to [_maxRadiusM] and the user's baseline minimum.
  static int _computeAdaptiveRadius({
    required double? speedMps,
    required String? radiusHint,
  }) {
    int baseline = AppConfig.searchRadiusMeters.round();
    if (radiusHint == 'tight') {
      baseline = 500;
    } else if (radiusHint == 'wide') {
      baseline = 1500;
    }

    if (speedMps == null || speedMps <= 0) return baseline;

    final speedRadius = baseline + (speedMps * _speedBufferSeconds).round();
    return speedRadius.clamp(baseline, _maxRadiusM);
  }

  static Future<PingOutcome> handlePosition(
    Position pos, {
    PingProgressCallback? onProgress,
    double minDistanceMeters = AppConfig.minDistanceMeters,
  }) async {
    onProgress?.call(RadarUiState.scanning);

    debugPrint(
      'Location -> lat=${pos.latitude} lon=${pos.longitude} acc=${pos.accuracy}m',
    );

    if (!await ConnectivityService.hasInternet()) {
      return PingOutcome(
        uiState: RadarUiState.error,
        isError: true,
        failure: PingFailure.noInternet,
        lat: pos.latitude,
        lon: pos.longitude,
        activityType: PingActivityType.error,
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final lastLat = prefs.getDouble(prefLastLat);
    final lastLon = prefs.getDouble(prefLastLon);

    double? distanceToNextSearchM;
    if (lastLat != null && lastLon != null) {
      final moved = Geolocator.distanceBetween(
        lastLat,
        lastLon,
        pos.latitude,
        pos.longitude,
      );
      distanceToNextSearchM =
          (minDistanceMeters - moved).clamp(0, minDistanceMeters);
    }

    final movedEnough = lastLat == null ||
        lastLon == null ||
        Geolocator.distanceBetween(
              lastLat,
              lastLon,
              pos.latitude,
              pos.longitude,
            ) >=
            minDistanceMeters;

    if (!movedEnough) {
      final remaining = distanceToNextSearchM ?? minDistanceMeters;
      return PingOutcome(
        uiState: RadarUiState.monitoring,
        statusMessage:
            'Walk ${remaining.toStringAsFixed(0)} m to trigger the next scan',
        isError: false,
        lat: pos.latitude,
        lon: pos.longitude,
        distanceToNextSearchM: remaining,
        activityType: PingActivityType.waiting,
      );
    }

    var token = prefs.getString(prefDeviceToken);
    if (token != null && !FcmService.isValidToken(token)) {
      debugPrint(
        'Ignoring invalid stored FCM token: ${token.substring(0, token.length.clamp(0, 16))}…',
      );
      token = null;
      await prefs.remove(prefDeviceToken);
    }

    token ??= await FcmService.currentToken();

    if (token == null && kDebugMode) {
      token = AppConfig.devDeviceToken;
      debugPrint(
        'Using dev device token (Firebase not configured — debug only)',
      );
    } else if (token == null) {
      return PingOutcome(
        uiState: RadarUiState.error,
        statusMessage:
            'Push token missing — restart the app with internet and notification permission',
        isError: true,
        failure: PingFailure.unknown,
        lat: pos.latitude,
        lon: pos.longitude,
        activityType: PingActivityType.error,
      );
    }

    if (!FcmService.isValidToken(token)) {
      return PingOutcome(
        uiState: RadarUiState.error,
        statusMessage: 'Invalid push token — cannot deliver notifications',
        isError: true,
        failure: PingFailure.unknown,
        lat: pos.latitude,
        lon: pos.longitude,
        activityType: PingActivityType.error,
      );
    }

    onProgress?.call(RadarUiState.scanning);
    debugPrint('Pinging backend with FCM token ${token.substring(0, 12)}…');

    final vectors = await _loadActiveVectors();
    final renderImages = await _loadRenderImages();
    final elaborate = await _loadElaborateText();
    final radiusHint = await _loadRadiusHint();
    final notificationFrequency = await _loadNotificationFrequency();
    // Speed-adaptive radius: at highway speeds the buffer grows to
    // give the driver time to react to a fuel / emergency alert.
    final adaptiveRadius = _computeAdaptiveRadius(
      speedMps: pos.speed,
      radiusHint: radiusHint,
    );
    final result = await ApiService.sendPing(
      lat: pos.latitude,
      lon: pos.longitude,
      deviceToken: token,
      activeVectors: vectors,
      renderImages: renderImages,
      elaborate: elaborate,
      radiusM: adaptiveRadius,
      notificationFrequency: notificationFrequency,
    );

    if (!result.isSuccess) {
      if (result.failure == PingFailure.timeout) {
        return PingOutcome(
          uiState: RadarUiState.processing,
          statusMessage: result.detail,
          isError: false,
          failure: PingFailure.timeout,
          lat: pos.latitude,
          lon: pos.longitude,
          activityType: PingActivityType.searching,
        );
      }
      return PingOutcome(
        uiState: RadarUiState.error,
        isError: true,
        failure: result.failure,
        lat: pos.latitude,
        lon: pos.longitude,
        activityType: PingActivityType.error,
      );
    }

    final data = result.data!;
    final status = data['status'] ?? 'unknown';
    final radiusUsedRaw = data['radius_used_m'];
    final radiusUsedM = radiusUsedRaw is num ? radiusUsedRaw.toInt() : null;
    final radiusExpanded =
        radiusUsedM != null && radiusUsedM > AppConfig.searchRadiusMeters;

    await prefs.setDouble(prefLastLat, pos.latitude);
    await prefs.setDouble(prefLastLon, pos.longitude);

    DiscoveryItem? discovery;
    if (status == 'notified') {
      final notifRaw = data['notification'];
      if (notifRaw is Map) {
        discovery = DiscoveryItem.fromPingNotification(
          Map<String, dynamic>.from(notifRaw),
          lat: pos.latitude,
          lon: pos.longitude,
        );
        debugPrint(
          'Discovery created: id=${discovery.id} title=${discovery.title} '
          'imageUrl=${discovery.imageUrl ?? "NULL"}',
        );
        await DiscoveryRepository.add(discovery);
      }
    }

    return switch (status) {
      'notified' => PingOutcome(
          uiState: RadarUiState.success,
          isError: false,
          rawStatus: status,
          lat: pos.latitude,
          lon: pos.longitude,
          distanceToNextSearchM: minDistanceMeters,
          activityType: PingActivityType.found,
          radiusUsedM: radiusUsedM,
          discovery: discovery,
          statusMessage: discovery != null
              ? '${discovery.title} — ${discovery.body}'
              : null,
        ),
      'no_places_found' => PingOutcome(
          uiState: RadarUiState.empty,
          statusMessage: radiusExpanded
              ? 'Scan complete: nothing found even after expanding search to $radiusUsedM m'
              : null,
          isError: false,
          rawStatus: status,
          lat: pos.latitude,
          lon: pos.longitude,
          distanceToNextSearchM: minDistanceMeters,
          activityType: PingActivityType.empty,
          radiusUsedM: radiusUsedM,
        ),
      'no_new_places' => PingOutcome(
          uiState: RadarUiState.empty,
          statusMessage: 'Nearby places already notified recently',
          isError: false,
          rawStatus: status,
          lat: pos.latitude,
          lon: pos.longitude,
          distanceToNextSearchM: minDistanceMeters,
          activityType: PingActivityType.empty,
          radiusUsedM: radiusUsedM,
        ),
      'error' => PingOutcome(
          uiState: RadarUiState.error,
          statusMessage:
              data['detail']?.toString() ?? 'Server could not generate a notification',
          isError: true,
          rawStatus: status,
          failure: PingFailure.serverError,
          lat: pos.latitude,
          lon: pos.longitude,
          activityType: PingActivityType.error,
          radiusUsedM: radiusUsedM,
        ),
      _ => PingOutcome(
          uiState: RadarUiState.empty,
          statusMessage: 'Server returned: $status',
          isError: status == 'error',
          rawStatus: status,
          lat: pos.latitude,
          lon: pos.longitude,
          distanceToNextSearchM: minDistanceMeters,
          activityType: PingActivityType.info,
          radiusUsedM: radiusUsedM,
        ),
    };
  }
}

enum PingActivityType { info, waiting, searching, found, empty, error }

class PingOutcome {
  const PingOutcome({
    required this.uiState,
    required this.isError,
    this.statusMessage,
    this.rawStatus,
    this.failure,
    this.lat,
    this.lon,
    this.distanceToNextSearchM,
    this.activityType = PingActivityType.info,
    this.radiusUsedM,
    this.discovery,
  });

  final RadarUiState uiState;
  final String? statusMessage;
  final bool isError;
  final String? rawStatus;
  final PingFailure? failure;
  final double? lat;
  final double? lon;
  final double? distanceToNextSearchM;
  final PingActivityType activityType;
  /// Effective search radius (metres) the backend used to find this result.
  /// May exceed [AppConfig.searchRadiusMeters] when the backend auto-expanded
  /// the search in a sparse area.
  final int? radiusUsedM;
  final DiscoveryItem? discovery;

  String get displayMessage =>
      statusMessage ?? uiState.detailMessage;
}
