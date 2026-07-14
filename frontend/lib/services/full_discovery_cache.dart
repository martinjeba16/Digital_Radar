import 'dart:convert';
import 'dart:io';

import '../models/full_discovery.dart';

class FullDiscoveryCache {
  static const _cacheDirName = 'digital_radar_discovery_cache';
  static const _ttlDays = 7;
  static const _maxCacheSizeBytes = 10 * 1024 * 1024;

  static Future<Directory> _getCacheDir() async {
    final dir = Directory('${Directory.systemTemp.path}/$_cacheDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _fileName(String notificationId) {
    return '${notificationId.hashCode.abs()}.json';
  }

  static Future<void> save(String notificationId, FullDiscovery discovery) async {
    try {
      final dir = await _getCacheDir();
      final file = File('${dir.path}/${_fileName(notificationId)}');
      final entry = {
        'data': discovery.copyWith(isCached: true).toJson(),
        'fetched_at': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(entry));
      await _enforceMaxSize(dir);
    } catch (e) {
      // fail silently — cache miss on next read is acceptable
    }
  }

  static Future<FullDiscovery?> get(String notificationId) async {
    try {
      final dir = await _getCacheDir();
      final file = File('${dir.path}/${_fileName(notificationId)}');
      if (!await file.exists()) return null;

      final raw = await file.readAsString();
      final entry = jsonDecode(raw) as Map<String, dynamic>;

      final fetchedAt = DateTime.parse(entry['fetched_at'] as String);
      if (DateTime.now().difference(fetchedAt).inDays > _ttlDays) {
        await file.delete();
        return null;
      }

      return FullDiscovery.fromJson(
        Map<String, dynamic>.from(entry['data'] as Map),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _enforceMaxSize(Directory dir) async {
    try {
      int totalSize = 0;
      final entries = <FileSystemEntity>[];
      await for (final entity in dir.list()) {
        entries.add(entity);
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      if (totalSize <= _maxCacheSizeBytes) return;

      entries.sort((a, b) {
        final aStat = a is File ? a.statSync() : null;
        final bStat = b is File ? b.statSync() : null;
        final aTime = aStat?.modified ?? DateTime(0);
        final bTime = bStat?.modified ?? DateTime(0);
        return aTime.compareTo(bTime);
      });

      for (final entity in entries) {
        if (totalSize <= _maxCacheSizeBytes) break;
        if (entity is File) {
          final len = await entity.length();
          await entity.delete();
          totalSize -= len;
        }
      }
    } catch (_) {}
  }
}
