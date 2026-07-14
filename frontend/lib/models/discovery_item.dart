class DiscoveryItem {
  final String id;
  final String title;
  final String body;
  final String? imageUrl;
  final String category;
  final String? tamilTitle;
  final String? tamilBody;
  final DateTime discoveredAt;
  final Map<String, dynamic> raw;

  // Source identifiers for fetching full content
  final int? pageid;
  final int? osmId;
  final String? osmType; // "node" | "way" | "relation"
  final String? source;
  final String? url;

  static const _nonRasterExtensions = {
    '.svg',
    '.ogg',
    '.ogv',
    '.oga',
    '.webm',
    '.mid',
    '.midi',
  };

  static String? _validImageUrl(String? url) {
    if (url == null || url.isEmpty || url == 'null') return null;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (_nonRasterExtensions.any((ext) => path.endsWith(ext))) return null;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    return url;
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  const DiscoveryItem({
    required this.id,
    required this.title,
    required this.body,
    this.imageUrl,
    required this.category,
    this.tamilTitle,
    this.tamilBody,
    required this.discoveredAt,
    required this.raw,
    this.pageid,
    this.osmId,
    this.osmType,
    this.source,
    this.url,
  });

  factory DiscoveryItem.fromJson(Map<String, dynamic> json) {
    final nested = json['raw'];
    final raw = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(json);
    return DiscoveryItem(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? 'Unknown',
      body: json['body']?.toString() ?? '',
      imageUrl: _validImageUrl(json['image_url']?.toString()),
      category: json['category']?.toString() ?? 'unknown',
      tamilTitle: json['tamil_title']?.toString(),
      tamilBody: json['tamil_body']?.toString(),
      discoveredAt: json['discovered_at'] != null
          ? DateTime.tryParse(json['discovered_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      raw: raw,
      pageid: _asInt(json['pageid']),
      osmId: _asInt(json['osm_id']),
      osmType: json['osm_type']?.toString(),
      source: json['source']?.toString(),
      url: json['url']?.toString(),
    );
  }

  factory DiscoveryItem.fromPingNotification(
    Map<String, dynamic> notification, {
    double? lat,
    double? lon,
    String? imageUrl,
  }) {
    final title = notification['title']?.toString() ?? 'Discovery';
    final body = notification['body']?.toString() ?? '';
    final locationId = notification['notification_id']?.toString() ??
        notification['location_id']?.toString() ??
        '';
    final now = DateTime.now();
    final id = locationId.isNotEmpty
        ? locationId
        : '${now.millisecondsSinceEpoch}_${title.hashCode}';
    return DiscoveryItem(
      id: id,
      title: title,
      body: body,
      imageUrl: _validImageUrl(imageUrl ?? notification['image_url']?.toString()),
      category: notification['category']?.toString() ?? 'nearby',
      discoveredAt: now,
      raw: {
        ...notification,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      },
      pageid: _asInt(notification['pageid']),
      osmId: _asInt(notification['osm_id']),
      osmType: notification['osm_type']?.toString(),
      source: notification['source']?.toString(),
      url: notification['url']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        if (imageUrl != null) 'image_url': imageUrl,
        'category': category,
        if (tamilTitle != null) 'tamil_title': tamilTitle,
        if (tamilBody != null) 'tamil_body': tamilBody,
        'discovered_at': discoveredAt.toIso8601String(),
        'raw': raw,
        if (pageid != null) 'pageid': pageid,
        if (osmId != null) 'osm_id': osmId,
        if (osmType != null) 'osm_type': osmType,
        if (source != null) 'source': source,
        if (url != null) 'url': url,
      };
}
