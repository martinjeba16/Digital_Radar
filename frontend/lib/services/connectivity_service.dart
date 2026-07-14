import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/api_result.dart';

/// Network checks before pinging and for UI status.
class ConnectivityService {
  static final Connectivity _connectivity = Connectivity();

  static Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;

  /// True when the device has Wi‑Fi or mobile data (not airplane mode).
  static Future<bool> hasInternet() async {
    final results = await _connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  /// Quick probe: can we open a TCP connection to the backend host?
  static Future<bool> canReachBackendHost() async {
    if (!await hasInternet()) return false;

    final uri = Uri.parse(AppConfig.apiBaseUrl);
    final host = uri.host;
    final port = uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port;

    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 8));
      await socket.close();
      return true;
    } catch (e) {
      debugPrint('Backend host unreachable ($host:$port): $e');
      return false;
    }
  }

  /// GET /api/v1/health — confirms API is up and MongoDB is connected.
  static Future<BackendHealthResult> checkBackendHealth() async {
    if (!await hasInternet()) {
      return const BackendHealthResult(
        reachable: false,
        message: 'No internet connection',
      );
    }

    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/v1/health');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return BackendHealthResult(
          reachable: false,
          message: 'Server returned HTTP ${response.statusCode}',
        );
      }

      final mongoOk = body.contains('"mongodb":true');
      if (!mongoOk) {
        return const BackendHealthResult(
          reachable: true,
          mongodbOk: false,
          message: 'Server is up but database is not connected',
        );
      }

      return const BackendHealthResult(
        reachable: true,
        mongodbOk: true,
        message: 'Server and database are ready',
      );
    } on SocketException {
      return BackendHealthResult(
        reachable: false,
        message: 'Cannot reach server at ${AppConfig.apiBaseUrl}',
      );
    } on TimeoutException {
      return const BackendHealthResult(
        reachable: false,
        message: 'Server health check timed out',
      );
    } catch (e) {
      debugPrint('Health check error: $e');
      return BackendHealthResult(
        reachable: false,
        message: 'Health check failed: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Run before starting radar — returns first blocking issue, if any.
  static Future<BackendHealthResult> runPreflightChecks() async {
    if (!await hasInternet()) {
      return const BackendHealthResult(
        reachable: false,
        message: 'No internet — turn on Wi‑Fi or mobile data',
      );
    }

    if (!await canReachBackendHost()) {
      return BackendHealthResult(
        reachable: false,
        message:
            'Cannot reach ${AppConfig.apiBaseUrl}. Is the EC2 server running?',
      );
    }

    return checkBackendHealth();
  }
}
