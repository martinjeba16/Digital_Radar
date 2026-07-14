import 'radar_ui_state.dart';

enum RadarActivityType {
  info,
  gps,
  waiting,
  searching,
  found,
  empty,
  error,
}

class RadarActivityEntry {
  const RadarActivityEntry({
    required this.time,
    required this.message,
    required this.type,
    this.headline,
    this.lat,
    this.lon,
    this.distanceToNextSearchM,
    this.uiState,
  });

  final DateTime time;
  final String message;
  final RadarActivityType type;
  final String? headline;
  final double? lat;
  final double? lon;
  final double? distanceToNextSearchM;
  final RadarUiState? uiState;
}

class RadarLiveState {
  const RadarLiveState({
    this.lat,
    this.lon,
    this.distanceToNextSearchM,
    this.lastScanAt,
    this.uiState = RadarUiState.idle,
    this.headline = 'Radar is off',
    this.detail = 'Tap Start to begin scanning nearby places.',
    this.isError = false,
    this.updatedAt,
  });

  final double? lat;
  final double? lon;
  final double? distanceToNextSearchM;
  final DateTime? lastScanAt;
  final RadarUiState uiState;
  final String headline;
  final String detail;
  final bool isError;
  final DateTime? updatedAt;

  RadarLiveState copyWith({
    double? lat,
    double? lon,
    double? distanceToNextSearchM,
    DateTime? lastScanAt,
    RadarUiState? uiState,
    String? headline,
    String? detail,
    bool? isError,
    DateTime? updatedAt,
  }) {
    return RadarLiveState(
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      distanceToNextSearchM:
          distanceToNextSearchM ?? this.distanceToNextSearchM,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      uiState: uiState ?? this.uiState,
      headline: headline ?? this.headline,
      detail: detail ?? this.detail,
      isError: isError ?? this.isError,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
