import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/api_result.dart';
import '../models/discovery_item.dart';
import '../models/full_discovery.dart';
import '../services/full_discovery_cache.dart';
import 'connectivity_service.dart';

/// Talks to the FastAPI backend.
class ApiService {
  /// POST the current location to /api/v1/ping.
  static Future<PingApiResult> sendPing({
    required double lat,
    required double lon,
    required String deviceToken,
    Map<String, bool>? activeVectors,
    bool renderImages = true,
    bool elaborate = false,
    String? radiusHint,
    int? radiusM,
    String? notificationFrequency,
  }) async {
    if (!await ConnectivityService.hasInternet()) {
      return PingApiResult.failure(
        PingFailure.noInternet,
        PingFailure.noInternet.userMessage,
      );
    }

    final uri = Uri.parse('${AppConfig.apiBaseUrl.trim()}/api/v1/ping');
    final apiKey = AppConfig.apiKeyClean;
    debugPrint(
      'Sending X-API-Key: ${apiKey.length > 8 ? "${apiKey.substring(0, 8)}…(${apiKey.length} chars)" : "<short-key>"}',
    );
    try {
      final resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': apiKey,
            },
            body: jsonEncode({
              'lat': lat,
              'lon': lon,
              'device_token': deviceToken,
              if (activeVectors != null) 'active_vectors': activeVectors,
              // radius_m (speed-adaptive numeric) and radius_hint (static
              // preset) are mutually exclusive — the backend prefers radius_m.
              if (radiusM != null) 'radius_m': radiusM,
              if (radiusM == null && radiusHint != null) 'radius_hint': radiusHint,
              if (notificationFrequency != null) 'notification_frequency': notificationFrequency,
              'render_images': renderImages,
              'elaborate': elaborate,
            }),
          )
          .timeout(Duration(seconds: AppConfig.pingTimeoutSeconds));

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        debugPrint(
          'Ping OK -> status=${decoded['status']} places=${decoded['place_count']}',
        );
        return PingApiResult.success(decoded);
      }
      if (resp.statusCode == 401) {
        return PingApiResult.failure(
          PingFailure.unauthorized,
          PingFailure.unauthorized.userMessage,
        );
      }
      if (resp.statusCode == 429) {
        return PingApiResult.failure(
          PingFailure.rateLimited,
          PingFailure.rateLimited.userMessage,
        );
      }
      if (resp.statusCode >= 500) {
        return PingApiResult.failure(
          PingFailure.serverError,
          'Server error (HTTP ${resp.statusCode})',
        );
      }

      debugPrint('Ping failed -> HTTP ${resp.statusCode}: ${resp.body}');
      return PingApiResult.failure(
        PingFailure.unknown,
        'Unexpected response (HTTP ${resp.statusCode})',
      );
    } on SocketException catch (e) {
      debugPrint('Ping socket error -> $e');
      return PingApiResult.failure(
        PingFailure.serverUnreachable,
        PingFailure.serverUnreachable.userMessage,
      );
    } on TimeoutException {
      debugPrint(
        'Ping timed out after ${AppConfig.pingTimeoutSeconds}s '
        '(server may still be generating — check notifications)',
      );
      return PingApiResult.failure(
        PingFailure.timeout,
        PingFailure.timeout.userMessage,
      );
    } catch (e) {
      debugPrint('Ping error -> $e');
      return PingApiResult.failure(PingFailure.unknown, e.toString());
    }
  }

  /// GET /api/v1/recents?device_token=...
  /// Returns the last 24h of AI-notified discoveries from the backend.
  static Future<List<DiscoveryItem>> fetchRecents(String deviceToken) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl.trim()}/api/v1/recents')
        .replace(queryParameters: {'device_token': deviceToken});
    final apiKey = AppConfig.apiKeyClean;

    try {
      final resp = await http
          .get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final itemsRaw = data['recents'];
        if (itemsRaw is List) {
          final items = itemsRaw
              .whereType<Map<String, dynamic>>()
              .map(DiscoveryItem.fromJson)
              .toList();
          return items;
        }
      }
      throw Exception('HTTP ${resp.statusCode}');
    } catch (e) {
      debugPrint('Fetch recents error: $e');
      rethrow;
    }
  }

  /// Prefetch full discovery content from /api/v1/discoveries/{id} and cache locally.
  /// Fire-and-forget: does not wait for result, just triggers background fetch.
  static Future<void> prefetchFullDiscovery(
      String notificationId, String deviceToken) async {
    try {
      final uri = Uri.parse(
          '${AppConfig.apiBaseUrl.trim()}/api/v1/discoveries/$notificationId')
          .replace(queryParameters: {'device_token': deviceToken});
      final apiKey = AppConfig.apiKeyClean;

      final resp = await http
          .get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final discovery = FullDiscovery.fromJson(data);
        await FullDiscoveryCache.save(notificationId, discovery);
        debugPrint('Prefetched full discovery: $notificationId');
      }
    } catch (e) {
      debugPrint('Prefetch full discovery error: $e');
    }
  }

  /// Fetch full discovery content, checking local cache first.
  /// Returns cached version if available (with isCached=true), otherwise fetches from network.
  static Future<FullDiscovery?> fetchFullDiscovery(
      String notificationId, String deviceToken) async {
    // Check cache first
    final cached = await FullDiscoveryCache.get(notificationId);
    if (cached != null) {
      debugPrint('Full discovery served from cache: $notificationId');
      return cached.copyWith(isCached: true);
    }

    // Not in cache, fetch from network
    try {
      final uri = Uri.parse(
          '${AppConfig.apiBaseUrl.trim()}/api/v1/discoveries/$notificationId')
          .replace(queryParameters: {'device_token': deviceToken});
      final apiKey = AppConfig.apiKeyClean;

      final resp = await http
          .get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final discovery = FullDiscovery.fromJson(data);
        // Save to cache for next time
        await FullDiscoveryCache.save(notificationId, discovery);
        debugPrint('Full discovery fetched and cached: $notificationId');
        return discovery;
      }
      debugPrint('Fetch full discovery failed: HTTP ${resp.statusCode}');
    } catch (e) {
      debugPrint('Fetch full discovery error: $e');
    }
    return null;
  }

  /// GET /api/v1/bookmarks?device_token=...
  /// Returns the full bookmarked [DiscoveryItem]s (content snapshot taken at
  /// bookmark-time), not just their IDs — so a bookmark survives even after
  /// its source discovery ages out of the local 24h ledger.
  static Future<List<DiscoveryItem>> fetchBookmarks(String deviceToken) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl.trim()}/api/v1/bookmarks')
        .replace(queryParameters: {'device_token': deviceToken});
    final apiKey = AppConfig.apiKeyClean;

    try {
      final resp = await http
          .get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final itemsRaw = data['bookmarked_items'];
        if (itemsRaw is List) {
          final items = itemsRaw
              .whereType<Map<String, dynamic>>()
              .map(DiscoveryItem.fromJson)
              .toList();
          return items;
        }
        final ids = (data['bookmarked_ids'] as List? ?? []).cast<String>();
        return ids
            .map((id) => DiscoveryItem(
                  id: id,
                  title: 'Saved discovery',
                  body: '',
                  category: 'unknown',
                  discoveredAt: DateTime.now(),
                  raw: const {},
                ))
            .toList();
      }
      throw Exception('HTTP ${resp.statusCode}');
    } catch (e) {
      debugPrint('Fetch bookmarks error: $e');
      rethrow;
    }
  }

  /// POST /api/v1/bookmarks — sends a full content snapshot so the backend
  /// can serve it back later even if it's gone from the local device ledger.
  static Future<bool> addBookmark(
    String deviceToken,
    String discoveryId, {
    DiscoveryItem? item,
  }) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final uri = Uri.parse('${AppConfig.apiBaseUrl.trim()}/api/v1/bookmarks');
      final apiKey = AppConfig.apiKeyClean;

      try {
        final resp = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'X-API-Key': apiKey,
              },
              body: jsonEncode({
                'device_token': deviceToken,
                'discovery_id': discoveryId,
                if (item != null) ...{
                  'title': item.title,
                  'body': item.body,
                  if (item.imageUrl != null) 'image_url': item.imageUrl,
                  'category': item.category,
                  if (item.tamilTitle != null) 'tamil_title': item.tamilTitle,
                  if (item.tamilBody != null) 'tamil_body': item.tamilBody,
                  'discovered_at': item.discoveredAt.toIso8601String(),
                  if (item.source != null) 'source': item.source,
                  if (item.pageid != null) 'pageid': item.pageid,
                  if (item.osmId != null) 'osm_id': item.osmId,
                  if (item.osmType != null) 'osm_type': item.osmType,
                  if (item.url != null) 'url': item.url,
                  if (item.raw['expanded_summary'] != null)
                    'expanded_summary': item.raw['expanded_summary'],
                  if (item.raw['poi_lat'] != null) 'poi_lat': item.raw['poi_lat'],
                  if (item.raw['poi_lon'] != null) 'poi_lon': item.raw['poi_lon'],
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 201) return true;
        debugPrint('Add bookmark attempt ${attempt + 1} failed: HTTP ${resp.statusCode}');
      } catch (e) {
        debugPrint('Add bookmark attempt ${attempt + 1} error: $e');
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  /// DELETE /api/v1/bookmarks/{discovery_id}?device_token=...
  static Future<bool> removeBookmark(String deviceToken, String discoveryId) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final uri = Uri.parse(
        '${AppConfig.apiBaseUrl.trim()}/api/v1/bookmarks/$discoveryId',
      ).replace(queryParameters: {'device_token': deviceToken});
      final apiKey = AppConfig.apiKeyClean;

      try {
        final resp = await http
            .delete(uri, headers: {'X-API-Key': apiKey})
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) return true;
        debugPrint('Remove bookmark attempt ${attempt + 1} failed: HTTP ${resp.statusCode}');
      } catch (e) {
        debugPrint('Remove bookmark attempt ${attempt + 1} error: $e');
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }
}
