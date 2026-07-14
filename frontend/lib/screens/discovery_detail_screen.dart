import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../models/full_discovery.dart';
import '../models/language_preference.dart';
import '../providers/radar_preferences_provider.dart';
import '../services/api_service.dart';
import '../services/full_discovery_cache.dart';

/// Full-screen "Read More" view opened from a notification action.
/// Initially shows compact AI summary; tapping "Load full details" fetches
/// and displays the full article/OSM element with gallery images.
class DiscoveryDetailScreen extends StatefulWidget {
  final DiscoveryItem item;
  final String? deviceToken;

  const DiscoveryDetailScreen({
    super.key,
    required this.item,
    this.deviceToken,
  });

  @override
  State<DiscoveryDetailScreen> createState() => _DiscoveryDetailScreenState();
}

class _DiscoveryDetailScreenState extends State<DiscoveryDetailScreen> {
  FullDiscovery? _fullDiscovery;
  bool _isLoadingFull = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _tryLoadCached();
  }

  Future<void> _tryLoadCached() async {
    if (widget.item.id.isEmpty || widget.deviceToken == null) return;
    final cached = await FullDiscoveryCache.get(widget.item.id);
    if (cached != null && mounted) {
      setState(() => _fullDiscovery = cached);
    }
  }

  Future<void> _loadFullDetails() async {
    if (_isLoadingFull || _fullDiscovery != null) return;

    final deviceToken = widget.deviceToken;
    if (deviceToken == null || deviceToken.isEmpty || widget.item.id.isEmpty) {
      setState(() => _loadError = 'Missing device token or discovery ID');
      return;
    }

    setState(() {
      _isLoadingFull = true;
      _loadError = null;
    });

    try {
      final discovery = await ApiService.fetchFullDiscovery(
        widget.item.id,
        deviceToken,
      );

      if (mounted) {
        if (discovery != null) {
          await FullDiscoveryCache.save(widget.item.id, discovery);
          setState(() => _fullDiscovery = discovery);
        } else {
          setState(() => _loadError = 'Could not load full details');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = 'Failed to load: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingFull = false);
      }
    }
  }

  bool get _showFullContent => _fullDiscovery != null;

  String _getDisplayTitle() {
    final prefs = context.read<RadarPreferencesProvider>();
    return prefs.currentLang == LanguagePreference.ta
        ? (widget.item.tamilTitle ?? widget.item.title)
        : widget.item.title;
  }

  String _getDisplayBody() {
    final prefs = context.read<RadarPreferencesProvider>();
    final isEnglish = prefs.currentLang == LanguagePreference.en;

    if (_showFullContent) {
      return _fullDiscovery!.fullText.isNotEmpty
          ? _fullDiscovery!.fullText
          : (isEnglish
              ? widget.item.body
              : (widget.item.tamilBody ?? widget.item.body));
    }

    final expanded = widget.item.raw['expanded_summary']?.toString();
    final body = (expanded != null && expanded.isNotEmpty)
        ? expanded
        : (isEnglish
            ? widget.item.body
            : (widget.item.tamilBody ?? widget.item.body));

    if (!prefs.useElaborateText && body.length > 120) {
      return '${body.substring(0, 120)}…';
    }
    return body;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final isBookmarked = prefs.pinnedDiscoveryIds.contains(widget.item.id);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discovery'),
        actions: [
          if (widget.deviceToken != null)
            IconButton(
              tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark',
              icon: Icon(isBookmarked ? Icons.bookmark : Icons.bookmark_border),
              onPressed: () => prefs.toggleBookmark(widget.item.id, widget.deviceToken!),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (widget.item.imageUrl != null && prefs.renderImages)
            SliverAppBar(
              expandedHeight: 220,
              pinned: false,
              flexibleSpace: FlexibleSpaceBar(
                background: CachedNetworkImage(
                  imageUrl: widget.item.imageUrl!,
                  fit: BoxFit.cover,
                  httpHeaders: ImageHttp.headers,
                  memCacheWidth: 800,
                  memCacheHeight: 450,
                  placeholder: (_, __) => Container(
                    color: colorScheme.surfaceContainerHighest,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                  errorWidget: (_, __, ___) => _ImageFallback(
                    category: widget.item.category,
                    colorScheme: colorScheme,
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Title
                Text(
                  _getDisplayTitle(),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                // Category chip row
                _CategoryRow(
                  category: widget.item.category,
                  colorScheme: colorScheme,
                  source: _showFullContent ? _fullDiscovery!.source : null,
                ),
                const SizedBox(height: 12),

                // Body text
                Text(
                  _getDisplayBody(),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.5,
                    color: colorScheme.onSurface.withValues(alpha: 0.85),
                  ),
                ),

                // Gallery (only when full content loaded and images enabled)
                if (prefs.renderImages &&
                    _showFullContent &&
                    _fullDiscovery!.images.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _Gallery(images: _fullDiscovery!.images.take(3).toList()),
                ],

                const SizedBox(height: 24),

                // Load full details button
                if (!_showFullContent) ...[
                  _LoadFullDetailsButton(
                    onPressed: _loadFullDetails,
                    isLoading: _isLoadingFull,
                    hasError: _loadError != null,
                    errorText: _loadError,
                  ),
                  const SizedBox(height: 16),
                ],

                // Source attribution
                if (_showFullContent && _fullDiscovery!.sourceUrl.isNotEmpty)
                  _SourceLink(url: _fullDiscovery!.sourceUrl, colorScheme: colorScheme),

                // Coordinates / Navigate button
                if (widget.item.raw['poi_lat'] != null && widget.item.raw['poi_lon'] != null)
                  _NavigateButton(
                    lat: (widget.item.raw['poi_lat'] as num).toDouble(),
                    lon: (widget.item.raw['poi_lon'] as num).toDouble(),
                    colorScheme: colorScheme,
                  ),

                // Language toggle
                const SizedBox(height: 16),
                Center(
                  child: InkWell(
                    onTap: prefs.toggleLanguage,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        prefs.currentLang.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String category;
  final ColorScheme colorScheme;
  final String? source;

  const _CategoryRow({
    required this.category,
    required this.colorScheme,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    IconData icon = Icons.place;
    Color color = colorScheme.primary;

    switch (category) {
      case 'food':
        icon = Icons.restaurant;
        color = Colors.orange.shade700;
        break;
      case 'travel_attractions':
        icon = Icons.attractions;
        color = Colors.blue.shade700;
        break;
      case 'essentials_transit':
        icon = Icons.local_gas_station;
        color = Colors.green.shade700;
        break;
      case 'history':
        icon = Icons.museum;
        color = Colors.purple.shade700;
        break;
      case 'mystery':
        icon = Icons.help_outline;
        color = Colors.teal.shade700;
        break;
    }

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        Chip(
          avatar: Icon(icon, size: 16, color: color),
          label: Text(category.replaceAll('_', ' ').toUpperCase()),
          backgroundColor: color.withValues(alpha: 0.1),
          labelStyle: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        if (source != null)
          Chip(
            label: Text(source!.toUpperCase()),
            labelStyle: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
            backgroundColor: colorScheme.surfaceContainerHighest,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }
}

class _LoadFullDetailsButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isLoading;
  final bool hasError;
  final String? errorText;

  const _LoadFullDetailsButton({
    required this.onPressed,
    required this.isLoading,
    this.hasError = false,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (hasError) {
      return Column(
        children: [
          FilledButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.errorContainer,
              foregroundColor: colorScheme.onErrorContainer,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              errorText!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      );
    }

    return FilledButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.article_outlined),
      label: Text(isLoading ? 'Loading…' : 'Load full details ▼'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Gallery extends StatelessWidget {
  final List<String> images;

  const _Gallery({required this.images});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Gallery',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: images.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 280,
                  child: CachedNetworkImage(
                    imageUrl: images[index],
                    fit: BoxFit.cover,
                    httpHeaders: ImageHttp.headers,
                    memCacheWidth: 560,
                    memCacheHeight: 360,
                    placeholder: (_, __) => Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorWidget: (_, __, ___) => _ImageFallback(
                      category: 'gallery',
                      colorScheme: colorScheme,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SourceLink extends StatelessWidget {
  final String url;
  final ColorScheme colorScheme;

  const _SourceLink({required this.url, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: TextButton.icon(
        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        icon: Icon(Icons.open_in_new, size: 16, color: colorScheme.primary),
        label: Text(
          'View source',
          style: theme.textTheme.labelLarge?.copyWith(color: colorScheme.primary),
        ),
      ),
    );
  }
}

class _NavigateButton extends StatelessWidget {
  final double lat;
  final double lon;
  final ColorScheme colorScheme;

  const _NavigateButton({
    required this.lat,
    required this.lon,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () async {
        final uri = Uri.parse('google.navigation:q=$lat,$lon');
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      icon: const Icon(Icons.directions),
      label: const Text('Navigate'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
      ),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  final String category;
  final ColorScheme colorScheme;

  const _ImageFallback({required this.category, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    switch (category) {
      case 'food':
        icon = Icons.restaurant;
        break;
      case 'travel_attractions':
        icon = Icons.attractions;
        break;
      case 'essentials_transit':
        icon = Icons.local_gas_station;
        break;
      case 'history':
        icon = Icons.museum;
        break;
      case 'mystery':
        icon = Icons.help_outline;
        break;
      default:
        icon = Icons.place;
    }

    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          icon,
          size: 48,
          color: colorScheme.onSurface.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}