import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';
import '../models/discovery_item.dart';
import '../models/radar_activity.dart';
import '../models/radar_ui_state.dart';
import 'adaptive_location_strategy.dart';
import 'location_ping_logic.dart';

/// Android foreground service so location pings continue with the screen off.
class RadarForegroundService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'digital_radar_fg',
        channelName: 'Digital Radar',
        channelDescription: 'Location tracking while radar is active',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          AppConfig.locationIntervalSeconds * 1000,
        ),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;

    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    final locationPermission = await Geolocator.checkPermission();
    if (locationPermission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }

    return true;
  }

  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    await init();
    await requestPermissions();

    if (await FlutterForegroundTask.isRunningService) {
      return true;
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Digital Radar active',
      notificationText: RadarUiState.scanning.detailMessage,
      callback: startCallback,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<bool> stop() async {
    if (!Platform.isAndroid) return true;
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }

}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_RadarTaskHandler());
}

class _RadarTaskHandler extends TaskHandler {
  final AdaptiveLocationStrategy _adaptive = AdaptiveLocationStrategy();
  bool _scanning = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _scan();
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    await _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _sendUiState(
          RadarUiState.error,
          detailOverride: 'Location service is disabled',
        );
        return;
      }

      _sendUiState(RadarUiState.scanning);

      final base = _adaptive.adaptiveSettings;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: base.accuracy,
          distanceFilter: base.distanceFilter,
          timeLimit: const Duration(seconds: 15),
        ),
      );

      _adaptive.feedPosition(pos);

      if (!_adaptive.hasEnteredNewCell(pos.latitude, pos.longitude)) {
        debugPrint('Background scan skipped — same cell');
        return;
      }

      final outcome = await LocationPingLogic.handlePosition(
        pos,
        onProgress: (state) => _sendUiState(state),
        minDistanceMeters: _adaptive.minDistanceMeters,
      );

      _sendUiState(
        outcome.uiState,
        detailOverride: outcome.displayMessage,
        lat: outcome.lat,
        lon: outcome.lon,
        distanceToNextSearchM: outcome.distanceToNextSearchM,
        activityType: _mapType(outcome.activityType),
        discovery: outcome.discovery,
      );
    } catch (e) {
      debugPrint('Foreground task location error: $e');
      _sendUiState(
        RadarUiState.error,
        detailOverride: 'Location error: $e',
      );
    } finally {
      _scanning = false;
    }
  }

  RadarActivityType _mapType(PingActivityType type) => switch (type) {
        PingActivityType.waiting => RadarActivityType.waiting,
        PingActivityType.searching => RadarActivityType.searching,
        PingActivityType.found => RadarActivityType.found,
        PingActivityType.empty => RadarActivityType.empty,
        PingActivityType.error => RadarActivityType.error,
        PingActivityType.info => RadarActivityType.info,
      };

  void _sendUiState(
    RadarUiState uiState, {
    String? detailOverride,
    double? lat,
    double? lon,
    double? distanceToNextSearchM,
    RadarActivityType activityType = RadarActivityType.searching,
    DiscoveryItem? discovery,
  }) {
    final message = detailOverride ?? uiState.detailMessage;
    FlutterForegroundTask.sendDataToMain({
      'message': message,
      'uiState': uiState.name,
      'isError': uiState.isError,
      'headline': uiState.headline,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (distanceToNextSearchM != null)
        'distanceToNextSearchM': distanceToNextSearchM,
      'activityType': activityType.name,
      if (discovery != null) 'discovery': discovery.toJson(),
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {}
}
