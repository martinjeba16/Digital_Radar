import 'dart:async';
import 'dart:io';

import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';
import '../models/api_result.dart';
import '../models/discovery_item.dart';
import '../models/radar_activity.dart';
import '../models/radar_ui_state.dart';
import 'adaptive_location_strategy.dart';
import 'connectivity_service.dart';
import 'location_ping_logic.dart';
import 'radar_foreground_service.dart';

typedef StatusCallback = void Function(
  RadarUiState uiState, {
  String? detailOverride,
});

typedef ActivityCallback = void Function(RadarActivityEntry entry);

typedef DiscoveryCallback = void Function(DiscoveryItem discovery);

/// Owns location permissions and coordinates foreground/background tracking.
class LocationService {
  StreamSubscription<Position>? _sub;
  StatusCallback? _statusListener;
  ActivityCallback? _activityListener;
  DiscoveryCallback? _discoveryListener;
  bool _tracking = false;
  bool _processing = false;
  Position? _pendingPosition;
  final AdaptiveLocationStrategy _adaptiveStrategy = AdaptiveLocationStrategy();

  void setStatusListener(StatusCallback listener) {
    _statusListener = listener;
  }

  void setActivityListener(ActivityCallback listener) {
    _activityListener = listener;
  }

  void setDiscoveryListener(DiscoveryCallback listener) {
    _discoveryListener = listener;
  }

  void _emitUiState(
    RadarUiState uiState, {
    String? detailOverride,
    String? headlineOverride,
    RadarActivityType type = RadarActivityType.info,
    double? lat,
    double? lon,
    double? distanceToNextSearchM,
    bool logActivity = true,
    bool updateStatus = true,
  }) {
    final detail = detailOverride ?? uiState.detailMessage;
    final headline = headlineOverride ?? uiState.headline;

    if (logActivity) {
      _activityListener?.call(
        RadarActivityEntry(
          time: DateTime.now(),
          message: detail,
          type: type,
          headline: headline,
          lat: lat,
          lon: lon,
          distanceToNextSearchM: distanceToNextSearchM,
          uiState: uiState,
        ),
      );
    }

    if (updateStatus) {
      _statusListener?.call(uiState, detailOverride: detailOverride);
    }
  }

  RadarActivityType _typeFromUiState(RadarUiState state) => switch (state) {
        RadarUiState.scanning => RadarActivityType.searching,
        RadarUiState.processing => RadarActivityType.searching,
        RadarUiState.success => RadarActivityType.found,
        RadarUiState.empty => RadarActivityType.empty,
        RadarUiState.error => RadarActivityType.error,
        RadarUiState.monitoring => RadarActivityType.waiting,
        _ => RadarActivityType.info,
      };

  Future<bool> ensurePermissions() async {
    _emitUiState(
      RadarUiState.starting,
      detailOverride: 'Checking location permissions…',
    );
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _emitUiState(
        RadarUiState.starting,
        detailOverride: 'Opening location settings — please enable GPS',
        logActivity: false,
        updateStatus: true,
      );
      await Geolocator.openLocationSettings();
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: 'Location permission is required for Digital Radar',
        headlineOverride: 'Permission denied',
        type: RadarActivityType.error,
      );
      return false;
    }

    if (Platform.isAndroid && permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        _emitUiState(
          RadarUiState.starting,
          detailOverride: 'Tip: choose "Allow all the time" for background tracking',
          logActivity: true,
          updateStatus: false,
        );
      }
    }

    return true;
  }

  Future<bool> runPreflightChecks() async {
    _emitUiState(
      RadarUiState.starting,
      detailOverride: 'Checking internet and server…',
    );
    final health = await ConnectivityService.runPreflightChecks();

    if (!health.reachable) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: health.message,
        headlineOverride: 'Cannot start',
        type: RadarActivityType.error,
      );
      return false;
    }

    if (health.mongodbOk == false) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: health.message,
        headlineOverride: 'Database offline',
        type: RadarActivityType.error,
      );
      return false;
    }

    _emitUiState(RadarUiState.ready);
    return true;
  }

  Future<bool> start() async {
    if (!await ensurePermissions()) return false;
    if (!await runPreflightChecks()) return false;

    _tracking = true;

    if (Platform.isAndroid) {
      await RadarForegroundService.init();
      final started = await RadarForegroundService.start();
      if (started) {
        _emitUiState(
          RadarUiState.monitoring,
          detailOverride:
              'Background tracking started — scans every ${AppConfig.locationIntervalSeconds}s',
          headlineOverride: 'Radar active',
        );
        return true;
      }
      _emitUiState(
        RadarUiState.monitoring,
        detailOverride: 'Using in-app tracking (foreground service unavailable)',
      );
    }

    _emitUiState(
      RadarUiState.monitoring,
      detailOverride: 'Listening for GPS updates…',
      headlineOverride: 'Radar active',
    );
    _sub = Geolocator.getPositionStream(
      locationSettings: _adaptiveStrategy.adaptiveSettings,
    ).listen(_onPosition, onError: (Object e) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: 'GPS error: $e',
        headlineOverride: 'Location error',
        type: RadarActivityType.error,
      );
    });

    unawaited(_runImmediateScan());
    return true;
  }

  Future<void> stop() async {
    _tracking = false;
    if (Platform.isAndroid) {
      await RadarForegroundService.stop();
    }
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _runImmediateScan() async {
    if (!_tracking) return;
    await _processPosition();
  }

  Future<void> _onPosition(Position pos) async {
    if (_processing) {
      _pendingPosition = pos;
      return;
    }
    await _processPosition(existingPosition: pos);
  }

  Future<void> _processPosition({Position? existingPosition}) async {
    if (_processing) return;
    _processing = true;
    try {
      _emitUiState(
        RadarUiState.scanning,
        type: RadarActivityType.searching,
      );

      Position pos;
      try {
        pos = existingPosition ??
            await Geolocator.getCurrentPosition(
              locationSettings: LocationSettings(
                accuracy: _adaptiveStrategy.adaptiveSettings.accuracy,
                distanceFilter: _adaptiveStrategy.adaptiveSettings.distanceFilter,
                timeLimit: const Duration(seconds: 15),
              ),
            );
      } catch (e) {
        _emitUiState(
          RadarUiState.error,
          detailOverride: 'Could not get GPS fix: $e',
          headlineOverride: 'GPS unavailable',
          type: RadarActivityType.error,
        );
        return;
      }

      _activityListener?.call(
        RadarActivityEntry(
          time: DateTime.now(),
          message:
              'GPS fix (${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)})',
          type: RadarActivityType.gps,
          lat: pos.latitude,
          lon: pos.longitude,
          uiState: RadarUiState.scanning,
        ),
      );

      _adaptiveStrategy.feedPosition(pos);

      if (!_adaptiveStrategy.hasEnteredNewCell(pos.latitude, pos.longitude)) {
        _emitUiState(
          RadarUiState.monitoring,
          detailOverride: 'Same cell — waiting for new area',
          logActivity: false,
          updateStatus: false,
        );
        return;
      }

      final outcome = await LocationPingLogic.handlePosition(
        pos,
        onProgress: (state) {
          _emitUiState(state, type: RadarActivityType.searching);
        },
        minDistanceMeters: _adaptiveStrategy.minDistanceMeters,
      );

      _applyOutcome(outcome);
    } finally {
      _processing = false;
      final pending = _pendingPosition;
      _pendingPosition = null;
      if (pending != null && _tracking) {
        unawaited(_processPosition(existingPosition: pending));
      }
    }
  }

  void _applyOutcome(PingOutcome outcome) {
    _emitUiState(
      outcome.uiState,
      detailOverride: outcome.displayMessage,
      type: _typeFromUiState(outcome.uiState),
      lat: outcome.lat,
      lon: outcome.lon,
      distanceToNextSearchM: outcome.distanceToNextSearchM,
    );
    if (outcome.discovery != null) {
      _discoveryListener?.call(outcome.discovery!);
    }
  }

  void handleTaskData(Object data) {
    if (data is! Map) return;

    final uiStateName = data['uiState'];
    final message = data['message'];
    if (message is! String) return;

    final uiState = uiStateName is String
        ? RadarUiState.values.firstWhere(
            (s) => s.name == uiStateName,
            orElse: () => RadarUiState.monitoring,
          )
        : RadarUiState.monitoring;

    final headline = data['headline'];
    final lat = data['lat'];
    final lon = data['lon'];
    final distance = data['distanceToNextSearchM'];
    final activityType = data['activityType'];

    RadarActivityType type = _typeFromUiState(uiState);
    if (activityType is String) {
      type = RadarActivityType.values.firstWhere(
        (t) => t.name == activityType,
        orElse: () => type,
      );
    }

    _activityListener?.call(
      RadarActivityEntry(
        time: DateTime.now(),
        message: message,
        type: type,
        headline: headline is String ? headline : uiState.headline,
        lat: lat is num ? lat.toDouble() : null,
        lon: lon is num ? lon.toDouble() : null,
        distanceToNextSearchM:
            distance is num ? distance.toDouble() : null,
        uiState: uiState,
      ),
    );

    _statusListener?.call(
      uiState,
      detailOverride: message,
    );
  }

  /// Cancel all listeners and release resources. Safe to call multiple times.
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _statusListener = null;
    _activityListener = null;
    _discoveryListener = null;
    _tracking = false;
  }

  Future<void> onConnectivityRestored() async {
    if (!await ConnectivityService.hasInternet()) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: PingFailure.noInternet.userMessage,
        headlineOverride: 'No internet',
        type: RadarActivityType.error,
      );
      return;
    }

    final health = await ConnectivityService.checkBackendHealth();
    if (!health.reachable) {
      _emitUiState(
        RadarUiState.error,
        detailOverride: health.message,
        headlineOverride: 'Server offline',
        type: RadarActivityType.error,
      );
    } else {
      _activityListener?.call(
        RadarActivityEntry(
          time: DateTime.now(),
          message: 'Connection restored — ${health.message}',
          type: RadarActivityType.info,
          headline: 'Radar active',
          uiState: RadarUiState.monitoring,
        ),
      );
    }
  }
}
