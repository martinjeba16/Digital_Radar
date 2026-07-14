/// Granular radar UI states shown in the Details card and headline area.
enum RadarUiState {
  idle,
  starting,
  ready,
  monitoring,
  scanning,
  processing,
  success,
  empty,
  error,
}

extension RadarUiStateCopy on RadarUiState {
  String get headline => switch (this) {
        RadarUiState.idle => 'Radar is off',
        RadarUiState.starting => 'Starting…',
        RadarUiState.ready => 'Ready',
        RadarUiState.monitoring => 'Radar active',
        RadarUiState.scanning => 'Radar active',
        RadarUiState.processing => 'Still processing',
        RadarUiState.success => 'Target acquired',
        RadarUiState.empty => 'Scan complete',
        RadarUiState.error => 'Signal lost',
      };

  /// Primary text shown in the Details box.
  String get detailMessage => switch (this) {
        RadarUiState.idle => 'Tap Start to begin scanning nearby places.',
        RadarUiState.starting => 'Checking permissions and server…',
        RadarUiState.ready => 'Server and database are ready.',
        RadarUiState.monitoring =>
          'Monitoring position — move 500 m to trigger the next scan.',
        RadarUiState.scanning => 'Scanning current location...',
        RadarUiState.processing =>
          'AI is taking longer than expected. Check notifications — '
          'the server may still be processing your scan.',
        RadarUiState.success =>
          'Discovery delivered — see your notification and ledger below.',
        RadarUiState.empty =>
          'Scan complete: No points of interest within range.',
        RadarUiState.error => 'Signal lost. Retrying connection...',
      };

  bool get isError => this == RadarUiState.error;
}
