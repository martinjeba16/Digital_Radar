import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

enum MotionState { stationary, walking, moving }

class AdaptiveLocationStrategy extends ChangeNotifier {
  static const double _cellSizeDeg = 0.001;

  String? _lastCellKey;
  final List<_PositionSample> _history = [];
  static const int _maxHistory = 6;
  MotionState _state = MotionState.stationary;

  static const Duration _stationaryTimeout = Duration(minutes: 3);
  static const double _walkingSpeedLimitMps = 2.0;
  static const double _minSignificantMoveM = 30;

  MotionState get state => _state;
  String? get lastCellKey => _lastCellKey;

  String cellKey(double lat, double lon) {
    final latCell = (lat / _cellSizeDeg).round() * _cellSizeDeg;
    final lonCell = (lon / _cellSizeDeg).round() * _cellSizeDeg;
    return '${latCell.toStringAsFixed(6)}_${lonCell.toStringAsFixed(6)}';
  }

  bool hasEnteredNewCell(double lat, double lon) {
    final key = cellKey(lat, lon);
    if (key == _lastCellKey) return false;
    _lastCellKey = key;
    return true;
  }

  void feedPosition(Position pos) {
    _history.add(_PositionSample(
      lat: pos.latitude,
      lon: pos.longitude,
      time: pos.timestamp,
    ));
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    _recompute();
  }

  void _recompute() {
    if (_history.length < 2) return;

    final first = _history.first;
    final last = _history.last;
    final distance = Geolocator.distanceBetween(
      first.lat, first.lon, last.lat, last.lon,
    );
    final elapsed = last.time.difference(first.time);

    if (distance < _minSignificantMoveM) {
      if (elapsed > _stationaryTimeout) {
        _apply(MotionState.stationary);
      }
    } else if (elapsed.inSeconds > 0) {
      final speedMps = distance / elapsed.inSeconds;
      _apply(speedMps > _walkingSpeedLimitMps
          ? MotionState.moving
          : MotionState.walking);
    }
  }

  void _apply(MotionState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  LocationSettings get adaptiveSettings {
    switch (_state) {
      case MotionState.stationary:
        return const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 200,
        );
      case MotionState.walking:
        return const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 50,
        );
      case MotionState.moving:
        return const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 30,
        );
    }
  }

  int get intervalSeconds {
    switch (_state) {
      case MotionState.stationary:
        return 300;
      case MotionState.walking:
        return 60;
      case MotionState.moving:
        return 30;
    }
  }

  double get minDistanceMeters {
    switch (_state) {
      case MotionState.stationary:
        return 500;
      case MotionState.walking:
        return 200;
      case MotionState.moving:
        return 100;
    }
  }

  void reset() {
    _lastCellKey = null;
    _history.clear();
    _apply(MotionState.stationary);
  }
}

class _PositionSample {
  final double lat;
  final double lon;
  final DateTime time;

  const _PositionSample({
    required this.lat,
    required this.lon,
    required this.time,
  });
}
