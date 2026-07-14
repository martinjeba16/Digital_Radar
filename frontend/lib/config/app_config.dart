/// App-wide configuration. In a real build, prefer --dart-define or a secrets
/// file that is git-ignored, rather than hard-coding the API key here.
class AppConfig {
  /// Base URL of your FastAPI backend.
  /// - Android emulator reaching host machine: http://10.0.2.2:8000
  /// - Physical device via USB (adb reverse):  http://127.0.0.1:8000
  /// - Production (EC2 + HTTPS):               https://api.yourdomain.com
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  /// Must match API_KEY in the backend .env file.
  /// Raw value from --dart-define (compile-time constant — may carry trailing
  /// whitespace if the shell wraps the argument).
  static const String apiKey = String.fromEnvironment(
    'API_KEY',
    defaultValue: 'change-me-to-a-long-random-string',
  );

  /// Always use this when sending headers — strips any accidental whitespace
  /// or hidden newline characters that PowerShell/bash can inject via
  /// --dart-define so the backend key comparison never fails on length.
  static String get apiKeyClean => apiKey.trim();

  // ── Battery-aware adaptive location ──
  /// Trigger a new ping only after moving at least this many metres.
  static const double minDistanceMeters = 500;

  /// How often the background foreground service samples location (seconds).
  static const int locationIntervalSeconds = 60;

  /// Must match backend SEARCH_RADIUS_M (for user-facing messages).
  static const double searchRadiusMeters = 800;

  /// How long to wait for /api/v1/ping (Overpass + Wikipedia + FCM).
  static const int pingTimeoutSeconds = 45;

  /// Fallback device token when Firebase is not configured (debug builds only).
  static const String devDeviceToken = 'dev-local-token';
}
