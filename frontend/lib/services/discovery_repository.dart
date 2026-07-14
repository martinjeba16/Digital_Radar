import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/discovery_item.dart';

class DiscoveryRepository {
  static const _storageKey = 'discoveries_v1';
  static const _retention = Duration(hours: 24);

  static List<DiscoveryItem>? _cache;
  static bool _flushScheduled = false;

  static Future<List<DiscoveryItem>> loadAll() async {
    if (_cache != null) return List.unmodifiable(_cache!);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) {
      _cache = [];
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final items = decoded
          .map((e) => DiscoveryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      _cache = _pruneOld(items);
      return List.unmodifiable(_cache!);
    } catch (_) {
      _cache = [];
      return [];
    }
  }

  static Future<void> add(DiscoveryItem item) async {
    _cache ??= [];
    _cache!.removeWhere((d) => d.id == item.id);
    _cache!.insert(0, item);
    _cache = _pruneOld(_cache!);
    _scheduleFlush();
  }

  static Future<void> clear() async {
    _cache = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  static void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    Future.microtask(() async {
      _flushScheduled = false;
      await _flush();
    });
  }

  static Future<void> _flush() async {
    final items = _cache;
    if (items == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(items.map((d) => d.toJson()).toList()),
    );
  }

  static List<DiscoveryItem> _pruneOld(List<DiscoveryItem> items) {
    final cutoff = DateTime.now().subtract(_retention);
    return items.where((d) => d.discoveredAt.isAfter(cutoff)).toList();
  }
}
