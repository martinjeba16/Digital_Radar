import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/language_preference.dart';
import '../models/discovery_item.dart';
import '../services/api_service.dart';
import '../services/discovery_repository.dart';
import '../services/location_ping_logic.dart';

/// Radius hint sent to backend to adjust starting search radius.
enum ScanRadiusHint { tight, normal, wide }

/// Notification frequency preset — controls how often notifications fire.
/// Sent to backend to scale cooldowns instead of hard-coding on server.
enum NotificationFrequency {
  low(
    label: 'Low (fewer)',
    description: 'Max 20/day, longer gaps',
  ),
  medium(
    label: 'Medium',
    description: 'Balanced (default)',
  ),
  high(
    label: 'High (more)',
    description: 'Up to 100/day, shorter gaps',
  );

  const NotificationFrequency({required this.label, required this.description});
  final String label;
  final String description;
}

extension ScanRadiusHintX on ScanRadiusHint {
  String get name => toString().split('.').last;
  String get label {
    switch (this) {
      case ScanRadiusHint.tight:
        return 'Tight (500m)';
      case ScanRadiusHint.normal:
        return 'Normal (800m)';
      case ScanRadiusHint.wide:
        return 'Wide (1.5km)';
    }
  }

}

class RadarPreferencesProvider extends ChangeNotifier {
  bool isDarkMode = false;
  bool renderImages = true;
  bool useElaborateText = true;
  bool notificationsEnabled = true;
  bool notificationImages = true;
  LanguagePreference currentLang = LanguagePreference.en;
  ScanRadiusHint radiusHint = ScanRadiusHint.normal;
  NotificationFrequency notificationFrequency = NotificationFrequency.medium;
  List<String> pinnedDiscoveryIds = [];
  List<DiscoveryItem> discoveries = [];
  List<DiscoveryItem> recents = [];

  /// Set by the UI to receive bookmark error messages (for SnackBar display).
  void Function(String message)? onBookmarkError;

  String? recentsError;
  String? bookmarksError;

  final Map<String, bool> _activeRadarVectors = {
    'food': true,
    'travel_attractions': true,
    'essentials_transit': true,
    'night_open': true,
    'repair': false,
    'hazard': false,
    'mystery': false,
    'history': false,
  };

  Map<String, bool> get activeRadarVectors => Map.unmodifiable(_activeRadarVectors);

  static const Map<String, String> vectorLabels = {
    'food': 'Food & Dining',
    'travel_attractions': 'Travel & Attractions',
    'essentials_transit': 'Essentials & Transit',
    'night_open': 'Night Open',
    'repair': 'Repair Shops',
    'hazard': 'Hazard & Incident Zones',
    'mystery': 'Mysterious Incidents',
    'history': 'Spoken-word Archive',
  };

  static const Map<String, IconData> vectorIcons = {
    'food': Icons.restaurant,
    'travel_attractions': Icons.flight,
    'essentials_transit': Icons.local_hospital,
    'night_open': Icons.nights_stay,
    'repair': Icons.build,
    'hazard': Icons.warning,
    'mystery': Icons.help_outline,
    'history': Icons.history_edu,
  };

  void toggleDarkMode() {
    isDarkMode = !isDarkMode;
    notifyListeners();
    _persistBool(LocationPingLogic.prefDarkMode, isDarkMode);
  }

  void toggleRenderImages() {
    renderImages = !renderImages;
    notifyListeners();
    _persistBool(LocationPingLogic.prefRenderImages, renderImages);
  }

  void toggleElaborateText() {
    useElaborateText = !useElaborateText;
    notifyListeners();
    _persistBool(LocationPingLogic.prefElaborateText, useElaborateText);
  }

  void toggleNotificationsEnabled() {
    notificationsEnabled = !notificationsEnabled;
    notifyListeners();
    _persistBool(LocationPingLogic.prefNotificationsEnabled, notificationsEnabled);
  }

  void toggleNotificationImages() {
    notificationImages = !notificationImages;
    notifyListeners();
    _persistBool(LocationPingLogic.prefNotificationImages, notificationImages);
  }

  void toggleLanguage() {
    currentLang = currentLang.toggle;
    notifyListeners();
    _persistLanguage();
  }

  Future<void> _persistLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', currentLang.name);
  }

  void setRadiusHint(ScanRadiusHint hint) {
    radiusHint = hint;
    _persistRadiusHint();
    notifyListeners();
  }

  Future<void> _persistRadiusHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('radius_hint', radiusHint.name);
  }

  void setNotificationFrequency(NotificationFrequency freq) {
    notificationFrequency = freq;
    _persistNotificationFrequency();
    notifyListeners();
  }

  Future<void> _persistNotificationFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('notification_frequency', notificationFrequency.name);
  }

  Future<void> _persistBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Loads persisted settings from disk. MUST be awaited before the first
  /// frame builds (see main()) so the UI never flashes the default theme
  /// before snapping to the user's saved Dark Mode preference.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    isDarkMode = prefs.getBool(LocationPingLogic.prefDarkMode) ?? isDarkMode;
    renderImages =
        prefs.getBool(LocationPingLogic.prefRenderImages) ?? renderImages;
    useElaborateText =
        prefs.getBool(LocationPingLogic.prefElaborateText) ?? useElaborateText;
    notificationsEnabled =
        prefs.getBool(LocationPingLogic.prefNotificationsEnabled) ?? notificationsEnabled;
    notificationImages =
        prefs.getBool(LocationPingLogic.prefNotificationImages) ?? notificationImages;
    final langStr = prefs.getString('language');
    if (langStr != null) {
      currentLang = LanguagePreference.values.firstWhere(
        (l) => l.name == langStr,
        orElse: () => LanguagePreference.en,
      );
    }
    final radiusStr = prefs.getString('radius_hint');
    if (radiusStr != null) {
      radiusHint = ScanRadiusHint.values.firstWhere(
        (e) => e.name == radiusStr,
        orElse: () => ScanRadiusHint.normal,
      );
    }

    final raw = prefs.getString('active_vectors');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (_activeRadarVectors.containsKey(entry.key)) {
            _activeRadarVectors[entry.key] = entry.value as bool;
          }
        }
      } catch (_) {}
    }
    final freqStr = prefs.getString('notification_frequency');
    if (freqStr != null) {
      notificationFrequency = NotificationFrequency.values.firstWhere(
        (f) => f.name == freqStr,
        orElse: () => NotificationFrequency.medium,
      );
    }
    await reloadDiscoveries();
    notifyListeners();
  }

  Future<void> reloadDiscoveries() async {
    discoveries = await DiscoveryRepository.loadAll();
    notifyListeners();
  }

  void toggleVector(String key) {
    if (_activeRadarVectors.containsKey(key)) {
      _activeRadarVectors[key] = !_activeRadarVectors[key]!;
      _persistActiveVectors();
      notifyListeners();
    }
  }

  Future<void> _persistActiveVectors() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_vectors', jsonEncode(_activeRadarVectors));
  }

  void addDiscovery(DiscoveryItem item) {
    discoveries.removeWhere((d) => d.id == item.id);
    discoveries.insert(0, item);
    notifyListeners();
    DiscoveryRepository.add(item);
  }

  Future<void> clearDiscoveries() async {
    discoveries.clear();
    await DiscoveryRepository.clear();
    notifyListeners();
  }

  /// Hydrates bookmark state from the backend on app launch (or when the FCM
  /// token first becomes available). Bookmarked items may have already aged
  /// out of the local 24h ledger, so we merge the server's content snapshot
  /// back into [discoveries] rather than only restoring the ID list.
  Future<void> loadBookmarks(String deviceToken) async {
    try {
      final items = await ApiService.fetchBookmarks(deviceToken);
      bookmarksError = null;
      pinnedDiscoveryIds = items.map((d) => d.id).toList();

      final existingIds = discoveries.map((d) => d.id).toSet();
      for (final item in items) {
        if (!existingIds.contains(item.id)) {
          discoveries.add(item);
        }
      }
    } catch (e) {
      bookmarksError = 'Failed to load bookmarks. Pull to retry.';
    }
    notifyListeners();
  }

  Future<void> loadRecents(String deviceToken) async {
    try {
      recents = await ApiService.fetchRecents(deviceToken);
      recentsError = null;
    } catch (e) {
      recentsError = 'Failed to load recents. Pull to retry.';
    }
    notifyListeners();
  }

  Future<void> toggleBookmark(String id, String deviceToken) async {
    final wasPinned = pinnedDiscoveryIds.contains(id);
    if (wasPinned) {
      pinnedDiscoveryIds.remove(id);
      notifyListeners();
      final ok = await ApiService.removeBookmark(deviceToken, id);
      if (!ok) {
        pinnedDiscoveryIds.add(id);
        notifyListeners();
        onBookmarkError?.call('Failed to remove bookmark — try again');
      }
    } else {
      pinnedDiscoveryIds.add(id);
      notifyListeners();
      DiscoveryItem? item;
      for (final d in discoveries) {
        if (d.id == id) {
          item = d;
          break;
        }
      }
      final ok = await ApiService.addBookmark(deviceToken, id, item: item);
      if (!ok) {
        pinnedDiscoveryIds.remove(id);
        notifyListeners();
        onBookmarkError?.call('Failed to save bookmark — try again');
      }
    }
  }

  void removeRecent(String id) {
    recents.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  /// Marks [id] as bookmarked in local state without a network round-trip.
  /// Used by the notification action handler after it has already POSTed.
  void markBookmarkedLocally(String id, {DiscoveryItem? item}) {
    if (!pinnedDiscoveryIds.contains(id)) {
      pinnedDiscoveryIds.add(id);
    }
    if (item != null) {
      addDiscovery(item);
    } else {
      notifyListeners();
    }
  }
}
