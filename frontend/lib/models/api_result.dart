/// Result of an API call with a user-facing error message when it fails.
class PingApiResult {
  const PingApiResult._({this.data, this.failure, this.detail = ''});

  const PingApiResult.success(Map<String, dynamic> data)
      : this._(data: data);

  const PingApiResult.failure(PingFailure failure, String detail)
      : this._(failure: failure, detail: detail);

  final Map<String, dynamic>? data;
  final PingFailure? failure;
  final String detail;

  bool get isSuccess => failure == null;
}

enum PingFailure {
  noInternet,
  serverUnreachable,
  timeout,
  unauthorized,
  rateLimited,
  serverError,
  unknown,
}

extension PingFailureMessage on PingFailure {
  String get userMessage => switch (this) {
        PingFailure.noInternet =>
          'No internet connection. Connect to Wi‑Fi or mobile data.',
        PingFailure.serverUnreachable =>
          'Cannot reach the Digital Radar server. It may be offline.',
        PingFailure.timeout =>
          'AI is taking longer than expected. Check notifications — '
          'the server may still be processing your scan.',
        PingFailure.unauthorized =>
          'App API key rejected by server. Reinstall with correct build.',
        PingFailure.rateLimited =>
          'Too many requests. Wait a few minutes and try again.',
        PingFailure.serverError =>
          'Server error while processing your location.',
        PingFailure.unknown => 'Something went wrong contacting the server.',
      };
}

class BackendHealthResult {
  const BackendHealthResult({
    required this.reachable,
    required this.message,
    this.mongodbOk,
  });

  final bool reachable;
  final String message;
  final bool? mongodbOk;
}
