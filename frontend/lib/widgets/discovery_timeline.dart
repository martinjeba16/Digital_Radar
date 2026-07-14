import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../models/language_preference.dart';
import '../providers/radar_preferences_provider.dart';

class DiscoveryTimeline extends StatelessWidget {
  final List<DiscoveryItem> items;
  final void Function(String id)? onToggleBookmark;

  const DiscoveryTimeline({
    super.key,
    required this.items,
    this.onToggleBookmark,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _buildEmptyState(context);
    }
    return _buildTimeline(context);
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.radar,
                size: 48,
                color: colorScheme.primary.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 12),
              Text(
                'Awaiting Discoveries',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Start the radar and walk around — new discoveries will appear here',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isLast = index == items.length - 1;

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 32,
                child: Column(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorScheme.primary,
                        border: Border.all(
                          color: colorScheme.surface,
                          width: 2,
                        ),
                      ),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 1,
                          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TimelineCard(
                    item: item,
                    onToggleBookmark: onToggleBookmark,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TimelineCard extends StatelessWidget {
  final DiscoveryItem item;
  final void Function(String id)? onToggleBookmark;

  const _TimelineCard({
    required this.item,
    this.onToggleBookmark,
  });

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final isEnglish = prefs.currentLang == LanguagePreference.en;
    final title = isEnglish
        ? item.title
        : (item.tamilTitle ?? item.title);
    final body = isEnglish
        ? item.body
        : (item.tamilBody ?? item.body);
    final displayBody = prefs.useElaborateText
        ? body
        : (body.length <= 120 ? body : '${body.substring(0, 120)}…');

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: prefs.renderImages && item.imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: item.imageUrl!,
                        fit: BoxFit.cover,
                        httpHeaders: ImageHttp.headers,
                        memCacheWidth: 96,
                        memCacheHeight: 96,
                        placeholder: (_, __) => _TimelineFallback(colorScheme),
                        errorWidget: (_, __, ___) => _TimelineFallback(colorScheme),
                      )
                    : _TimelineFallback(colorScheme),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatTime(item.discoveredAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    displayBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                prefs.pinnedDiscoveryIds.contains(item.id)
                    ? Icons.bookmark
                    : Icons.bookmark_border,
                size: 16,
              ),
              onPressed: () => onToggleBookmark?.call(item.id),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineFallback extends StatelessWidget {
  final ColorScheme colorScheme;
  const _TimelineFallback(this.colorScheme);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Icon(
        Icons.place,
        size: 24,
        color: colorScheme.onPrimaryContainer.withValues(alpha: 0.4),
      ),
    );
  }
}
