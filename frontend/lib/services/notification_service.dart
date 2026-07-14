import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../providers/radar_preferences_provider.dart';
import '../screens/bookmarks_screen.dart';
import '../screens/discovery_detail_screen.dart';
import 'api_service.dart';
import 'app_navigator.dart';
import 'discovery_repository.dart';
import 'location_ping_logic.dart';

/// Top-level background action handler required by flutter_local_notifications.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) {
  WidgetsFlutterBinding.ensureInitialized();
  NotificationService.handleAction(response, fromBackground: true);
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'digital_radar_channel';
  static const _channelName = 'Digital Radar';
  static const _notificationId = 42;
  static const _groupKey = 'digital_radar_discoveries';

  static const _nonRasterExtensions = {'.svg', '.ogg', '.ogv', '.oga', '.webm', '.mid', '.midi'};

  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _maxCacheBytes = 50 * 1024 * 1024;
  static Directory? _cacheDir;
  static int _badgeCount = 0;

  /// Respects Settings → Notification Images even in the background isolate
  /// (where [preferences] is null).
  static Future<bool> _shouldShowNotificationImages() async {
    if (preferences != null) return preferences!.notificationImages;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(LocationPingLogic.prefNotificationImages) ?? true;
    } catch (_) {
      return true;
    }
  }

  static bool _isRasterImage(String url) {
    final lower = url.toLowerCase();
    // Reject known non-raster by extension, but allow URLs without an
    // extension (Wikimedia thumbnails / Special:FilePath?width=…).
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? lower;
    return !_nonRasterExtensions.any((ext) => path.endsWith(ext));
  }

  /// True when the first bytes look like JPEG / PNG / WebP / GIF / BMP.
  static bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // GIF
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // BMP
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  static RadarPreferencesProvider? preferences;

  static String _cacheKey(String url) {
    final bytes = utf8.encode(url);
    final key = base64Url.encode(bytes);
    return key.length > 120 ? key.substring(0, 120) : key;
  }

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir == null) {
      _cacheDir = Directory('${Directory.systemTemp.path}/digital_radar_notif_cache');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
    }
    return _cacheDir!;
  }

  static final Set<String> _validContentTypes = {
    'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/bmp',
  };

  /// Returns the cached image [File] if still fresh (< 24h), or downloads and
  /// caches it. Returns null on failure.
  ///
  /// Critical: Wikimedia Commons / Wikipedia CDN block the default Dart
  /// User-Agent. We always send [_httpUserAgent]. We also accept images by
  /// magic-byte sniffing when Content-Type is missing or wrong (Commons
  /// redirects sometimes return ``application/octet-stream``).
  static Future<File?> _getImageFile(String imageUrl) async {
    try {
      final dir = await _getCacheDir();
      final key = _cacheKey(imageUrl);
      final cacheFile = File('${dir.path}/$key');
      if (await cacheFile.exists()) {
        final age = DateTime.now().difference(await cacheFile.lastModified());
        if (age.inHours < 24 && await cacheFile.length() > 0) {
          debugPrint('Notification image cache HIT (${age.inMinutes}m old)');
          return cacheFile;
        }
      }
    } catch (e) {
      debugPrint('Notification image cache check failed: $e');
    }

    try {
      debugPrint('Downloading notification image: $imageUrl');
      final resp = await http
          .get(
            Uri.parse(imageUrl),
            headers: ImageHttp.headers,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        debugPrint(
          'Notification image HTTP ${resp.statusCode} for $imageUrl',
        );
        return null;
      }

      final bytes = resp.bodyBytes;
      if (bytes.isEmpty) {
        debugPrint('Notification image empty body');
        return null;
      }
      if (bytes.length > _maxImageBytes) {
        debugPrint(
          'Notification image too large (${bytes.length} bytes) — skipped',
        );
        return null;
      }

      final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
      final typeOk = _validContentTypes.any((t) => contentType.startsWith(t));
      final magicOk = _looksLikeImage(bytes);
      if (!typeOk && !magicOk) {
        debugPrint(
          'Notification image rejected — content-type="$contentType" '
          'magic=$magicOk size=${bytes.length}',
        );
        return null;
      }
      if (!typeOk && magicOk) {
        debugPrint(
          'Notification image accepted via magic bytes '
          '(content-type="$contentType")',
        );
      }

      final dir = await _getCacheDir();
      final cacheFile = File('${dir.path}/${_cacheKey(imageUrl)}');
      await cacheFile.writeAsBytes(bytes, flush: true);
      await _enforceCacheSize();
      debugPrint(
        'Notification image cached (${bytes.length} bytes) → ${cacheFile.path}',
      );
      return cacheFile;
    } catch (e) {
      debugPrint('Notification image download failed: $e');
      return null;
    }
  }

  static Future<void> _enforceCacheSize() async {
    try {
      final dir = await _getCacheDir();
      int total = 0;
      final files = <FileSystemEntity>[];
      await for (final entity in dir.list()) {
        files.add(entity);
        if (entity is File) {
          total += await entity.length();
        }
      }
      if (total <= _maxCacheBytes) return;

      files.sort((a, b) {
        final aStat = a is File ? a.statSync() : null;
        final bStat = b is File ? b.statSync() : null;
        return (aStat?.modified ?? DateTime(0)).compareTo(bStat?.modified ?? DateTime(0));
      });

      for (final entity in files) {
        if (total <= _maxCacheBytes) break;
        if (entity is File) {
          total -= await entity.length();
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  /// Clears all cached notification images from disk.
  static Future<void> clearImageCache() async {
    try {
      final dir = await _getCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        _cacheDir = null;
      }
    } catch (_) {}
  }

  static Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        handleAction(response, fromBackground: false);
      },
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'Proactive location-based discoveries',
          importance: Importance.high,
        ));

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse != null) {
      Future.microtask(
        () => handleAction(
          launch!.notificationResponse!,
          fromBackground: false,
          fromColdStart: true,
        ),
      );
    }
  }

  static Future<void> handleAction(
    NotificationResponse response, {
    required bool fromBackground,
    bool fromColdStart = false,
  }) async {
    final actionId = response.actionId;
    final raw = response.payload;
    debugPrint(
      'Notification action: id=$actionId payload=${raw?.substring(0, (raw.length).clamp(0, 80))}… '
      'bg=$fromBackground cold=$fromColdStart',
    );

    final data = _decodePayload(raw);
    if (data == null) {
      debugPrint('Notification action ignored — empty/invalid payload');
      return;
    }

    switch (actionId) {
      case 'bookmark':
        await _handleBookmark(data, fromBackground: fromBackground);
        return;
      case 'navigate':
        await _handleNavigate(data);
        return;
      case 'read_more':
      case null:
      case '':
        await _handleReadMore(data, fromBackground: fromBackground);
        return;
      default:
        debugPrint('Unknown notification action: $actionId');
    }
  }

  static Map<String, dynamic>? _decodePayload(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      final parts = raw.split(',');
      if (parts.length >= 2) {
        return {'lat': parts[0], 'lon': parts[1]};
      }
    }
    return null;
  }

  static Future<void> _handleNavigate(Map<String, dynamic> data) async {
    final lat = (data['poi_lat'] ?? data['lat'])?.toString();
    final lon = (data['poi_lon'] ?? data['lon'])?.toString();
    if (lat == null || lon == null || lat.isEmpty || lon.isEmpty) {
      debugPrint('Navigate skipped — missing lat/lon');
      return;
    }
    final uri = Uri.parse('google.navigation:q=$lat,$lon');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    debugPrint('Navigate launched=$ok → $uri');
  }

  static Future<void> _handleBookmark(
    Map<String, dynamic> data, {
    bool fromBackground = false,
  }) async {
    var deviceToken = data['device_token']?.toString();
    if (deviceToken == null || deviceToken.isEmpty || deviceToken == 'null') {
      deviceToken = await LocationPingLogic.getDeviceToken();
    }
    final discoveryId = data['location_id']?.toString() ?? '';
    if (deviceToken == null || deviceToken.isEmpty || discoveryId.isEmpty) {
      debugPrint(
        'Bookmark skipped — token=${deviceToken?.substring(0, 12)} id=$discoveryId',
      );
      return;
    }

    final item = DiscoveryItem(
      id: discoveryId,
      title: data['title']?.toString() ?? 'Discovery',
      body: data['body']?.toString() ?? '',
      imageUrl: data['image_url']?.toString(),
      category: data['category']?.toString() ?? 'nearby',
      discoveredAt: DateTime.now(),
      raw: {
        ...data,
        'expanded_summary': data['expanded_summary'],
        if (data['lat'] != null) 'lat': data['lat'],
        if (data['lon'] != null) 'lon': data['lon'],
        if (data['poi_lat'] != null) 'poi_lat': data['poi_lat'],
        if (data['poi_lon'] != null) 'poi_lon': data['poi_lon'],
      },
    );

    await DiscoveryRepository.add(item);

    final ok = await ApiService.addBookmark(
      deviceToken,
      discoveryId,
      item: item,
    );
    debugPrint(
      'Bookmark POST ok=$ok id=$discoveryId imageUrl=${item.imageUrl ?? "NULL"}',
    );

    if (deviceToken.isNotEmpty && discoveryId.isNotEmpty) {
      unawaited(ApiService.prefetchFullDiscovery(discoveryId, deviceToken));
    }

    if (!fromBackground) {
      preferences?.markBookmarkedLocally(discoveryId, item: item);
    }

    await _plugin.show(
      discoveryId.hashCode & 0x7fffffff,
      'Bookmarked',
      item.title,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.low,
          priority: Priority.low,
          actions: [],
        ),
      ),
    );

    final token = deviceToken;
    final nav = AppNavigator.state;
    if (nav != null && ok) {
      await nav.push(
        MaterialPageRoute(builder: (_) => BookmarksScreen(deviceToken: token)),
      );
    } else if (ok) {
      AppNavigator.setPending({
        'type': 'bookmarks',
        'device_token': token,
      });
    }
  }

  static Future<void> _handleReadMore(
    Map<String, dynamic> data, {
    bool fromBackground = false,
  }) async {
    final discoveryId = data['location_id']?.toString() ?? '';
    final item = DiscoveryItem(
      id: discoveryId.isNotEmpty
          ? discoveryId
          : DateTime.now().millisecondsSinceEpoch.toString(),
      title: data['title']?.toString() ?? 'Discovery',
      body: data['body']?.toString() ?? '',
      imageUrl: data['image_url']?.toString(),
      category: data['category']?.toString() ?? 'nearby',
      discoveredAt: DateTime.now(),
      raw: {
        ...data,
        'expanded_summary': data['expanded_summary'],
      },
    );

    await DiscoveryRepository.add(item);
    if (!fromBackground) {
      preferences?.addDiscovery(item);
    }
    debugPrint(
      'Read More: id=${item.id} title=${item.title} imageUrl=${item.imageUrl ?? "NULL"}',
    );

    final deviceToken = (data['device_token']?.toString() ??
            await LocationPingLogic.getDeviceToken()) ??
        '';

    if (deviceToken.isNotEmpty && item.id.isNotEmpty) {
      unawaited(ApiService.prefetchFullDiscovery(item.id, deviceToken));
    }

    final route = DiscoveryDetailScreen(
      item: item,
      deviceToken: deviceToken,
    );

    final nav = AppNavigator.state;
    if (nav != null) {
      await nav.push(MaterialPageRoute(builder: (_) => route));
      return;
    }

    AppNavigator.setPending({
      'type': 'read_more',
      'item': item.toJson(),
      'device_token': deviceToken,
    });
    debugPrint('Read More queued — navigator not ready yet');
  }

  static Future<void> consumePendingAction() async {
    final pending = AppNavigator.takePending();
    if (pending == null) return;

    if (pending['type'] == 'read_more') {
      final raw = pending['item'];
      if (raw is! Map) return;
      final item = DiscoveryItem.fromJson(Map<String, dynamic>.from(raw));
      final token = pending['device_token']?.toString();
      final nav = AppNavigator.state;
      if (nav == null) return;
      await nav.push(
        MaterialPageRoute(
          builder: (_) => DiscoveryDetailScreen(
            item: item,
            deviceToken: token,
          ),
        ),
      );
    } else if (pending['type'] == 'bookmarks') {
      final token = pending['device_token']?.toString();
      if (token == null) return;
      final nav = AppNavigator.state;
      if (nav == null) return;
      await nav.push(
        MaterialPageRoute(builder: (_) => BookmarksScreen(deviceToken: token)),
      );
    }
  }

  /// Downloads image FIRST, then shows the notification with BigPictureStyle
  /// (or BigTextStyle fallback). No flash — the image is ready before display.
  static Future<void> showRich({
    required String title,
    required String body,
    String expandedSummary = '',
    String? imageUrl,
    String locationId = '',
    String lat = '',
    String lon = '',
    String poiLat = '',
    String poiLon = '',
    String? deviceToken,
    String category = 'nearby',
  }) async {
    // Respect user's notification preference (foreground only).
    if (preferences != null && !preferences!.notificationsEnabled) {
      debugPrint('Notification suppressed — disabled in settings');
      return;
    }

    final token = (deviceToken != null && deviceToken.isNotEmpty)
        ? deviceToken
        : await LocationPingLogic.getDeviceToken();

    final actions = <AndroidNotificationAction>[
      const AndroidNotificationAction(
        'navigate',
        'Navigate',
        showsUserInterface: true,
      ),
      const AndroidNotificationAction(
        'read_more',
        'Read More',
        showsUserInterface: true,
      ),
      const AndroidNotificationAction(
        'bookmark',
        'Bookmark',
        showsUserInterface: true,
      ),
    ];

    final payload = jsonEncode({
      'title': title,
      'body': body,
      'expanded_summary': expandedSummary,
      'image_url': imageUrl,
      'location_id': locationId,
      'lat': lat,
      'lon': lon,
      'poi_lat': poiLat,
      'poi_lon': poiLon,
      'device_token': token,
      'category': category,
    });

    final notifId = locationId.isNotEmpty
        ? (locationId.hashCode & 0x7fffffff)
        : _notificationId;

    // --- Download and cache image BEFORE showing the notification ---
    File? imageFile;
    Uint8List? imageBytes;
    final showImages = await _shouldShowNotificationImages();
    debugPrint(
      'showRich: imageUrl=${imageUrl ?? "NULL"} showImages=$showImages '
      'locationId=$locationId',
    );
    if (imageUrl == null || imageUrl.isEmpty) {
      debugPrint(
        'showRich: FCM payload has no image_url — text-only notification',
      );
    } else if (!showImages) {
      debugPrint('showRich: notificationImages disabled in settings');
    } else if (!_isRasterImage(imageUrl)) {
      debugPrint('showRich: rejected non-raster URL: $imageUrl');
    } else {
      imageFile = await _getImageFile(imageUrl);
      if (imageFile != null) {
        imageBytes = await imageFile.readAsBytes();
      } else {
        debugPrint('showRich: image download failed — falling back to BigText');
      }
    }

    _badgeCount++;

    // Collapsed notification: title + short 1-2 line preview only.
    // Expanding the notification (system "Show more") reveals the full
    // content.  For BigPicture, Android's API shows the same text in both
    // collapsed and expanded (no "expanded body" separate from preview),
    // but the big image adds value in the expanded state.
    final collapsedText = body.length > 120 ? '${body.substring(0, 117)}…' : body;
    final expandedText = expandedSummary.isNotEmpty ? expandedSummary : collapsedText;

    final style = imageBytes != null
        ? BigPictureStyleInformation(
            ByteArrayAndroidBitmap(imageBytes),
            largeIcon: ByteArrayAndroidBitmap(imageBytes),
            contentTitle: title,
            summaryText: collapsedText,
            hideExpandedLargeIcon: true,
          )
        : BigTextStyleInformation(
            expandedText,
            contentTitle: title,
            summaryText: collapsedText,
          );

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: style,
      // Also set largeIcon at the details level for OEMs that ignore the
      // style's largeIcon when the notification is collapsed.
      largeIcon:
          imageBytes != null ? ByteArrayAndroidBitmap(imageBytes) : null,
      actions: actions,
      category: AndroidNotificationCategory.recommendation,
      groupKey: _groupKey,
      number: _badgeCount,
    );

    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      badgeNumber: _badgeCount,
      threadIdentifier: _groupKey,
      attachments: imageFile != null
          ? [DarwinNotificationAttachment(imageFile.path)]
          : null,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
    );

    await _plugin.show(notifId, title, body, details, payload: payload);
    debugPrint(
      'Notification shown: id=$notifId hasImage=${imageBytes != null} '
      'badge=$_badgeCount',
    );
  }
}
