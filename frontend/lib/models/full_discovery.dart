/// Full discovery content fetched from backend /discoveries endpoint.
class FullDiscovery {
  final String notificationId;
  final String title;
  final String aiSummary;
  final String fullText;
  final String source; // "wikipedia" | "overpass" | "custom"
  final List<String> images; // max 3
  final FullCoordinates coordinates;
  final String sourceUrl;
  final List<String> categories;
  final DateTime fetchedAt;
  final bool isCached;

  const FullDiscovery({
    required this.notificationId,
    required this.title,
    required this.aiSummary,
    required this.fullText,
    required this.source,
    required this.images,
    required this.coordinates,
    required this.sourceUrl,
    required this.categories,
    required this.fetchedAt,
    this.isCached = false,
  });

  factory FullDiscovery.fromJson(Map<String, dynamic> json) {
    return FullDiscovery(
      notificationId: json['notification_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      aiSummary: json['ai_summary'] as String? ?? '',
      fullText: json['full_text'] as String? ?? '',
      source: json['source'] as String? ?? 'unknown',
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      coordinates: FullCoordinates.fromJson(
          json['coordinates'] as Map<String, dynamic>? ?? {}),
      sourceUrl: json['source_url'] as String? ?? '',
      categories: (json['categories'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      fetchedAt: DateTime.tryParse(json['fetched_at'] as String? ?? '') ??
          DateTime.now(),
      isCached: json['is_cached'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'notification_id': notificationId,
      'title': title,
      'ai_summary': aiSummary,
      'full_text': fullText,
      'source': source,
      'images': images,
      'coordinates': coordinates.toJson(),
      'source_url': sourceUrl,
      'categories': categories,
      'fetched_at': fetchedAt.toIso8601String(),
      'is_cached': isCached,
    };
  }

  FullDiscovery copyWith({bool? isCached}) {
    return FullDiscovery(
      notificationId: notificationId,
      title: title,
      aiSummary: aiSummary,
      fullText: fullText,
      source: source,
      images: images,
      coordinates: coordinates,
      sourceUrl: sourceUrl,
      categories: categories,
      fetchedAt: fetchedAt,
      isCached: isCached ?? this.isCached,
    );
  }
}

class FullCoordinates {
  final double lat;
  final double lon;

  const FullCoordinates({required this.lat, required this.lon});

  factory FullCoordinates.fromJson(Map<String, dynamic> json) {
    return FullCoordinates(
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lon: (json['lon'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {'lat': lat, 'lon': lon};
  }
}