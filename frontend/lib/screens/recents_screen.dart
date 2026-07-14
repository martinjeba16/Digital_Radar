import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../models/language_preference.dart';
import '../providers/radar_preferences_provider.dart';
import 'discovery_detail_screen.dart';

/// Displays the last 24 hours of AI-notified discoveries from the backend.
class RecentsScreen extends StatefulWidget {
  final String deviceToken;

  const RecentsScreen({super.key, required this.deviceToken});

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  bool _loading = false;
  String? _selectedCategory;

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await context.read<RadarPreferencesProvider>().loadRecents(widget.deviceToken);
    if (mounted) setState(() => _loading = false);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  List<String> _availableCategories(List<DiscoveryItem> items) {
    final cats = items.map((e) => e.category).toSet();
    return RadarPreferencesProvider.vectorIcons.keys
        .where((k) => cats.contains(k))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final recents = prefs.recents;
    final filtered = _selectedCategory == null
        ? recents
        : recents.where((d) => d.category == _selectedCategory).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recents'),
        actions: [
          if (recents.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Last 24 hours',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${recents.length} discoveries in the last 24 hours'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
        ],
      ),
      body: _loading && recents.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : (prefs.recentsError != null && recents.isEmpty)
              ? _buildErrorState(colorScheme, theme, prefs.recentsError!)
              : recents.isEmpty
              ? _buildEmptyState(colorScheme, theme)
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        sliver: SliverToBoxAdapter(
                          child: _buildHeader(colorScheme, theme, recents.length),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _buildFilterChips(recents, prefs),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverList.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final item = filtered[index];
                            final isLast = index == filtered.length - 1;
                            return _buildTimelineItem(
                              context,
                              item,
                              isLast,
                              colorScheme,
                              theme,
                              widget.deviceToken,
                            );
                          },
                        ),
                      ),
                      const SliverPadding(
                        padding: EdgeInsets.only(bottom: 32),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildFilterChips(List<DiscoveryItem> items, RadarPreferencesProvider prefs) {
    final cats = _availableCategories(items);
    if (cats.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip('All', null, Icons.explore),
            const SizedBox(width: 8),
            for (final cat in cats)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _filterChip(
                  RadarPreferencesProvider.vectorLabels[cat] ?? cat,
                  cat,
                  RadarPreferencesProvider.vectorIcons[cat] ?? Icons.place,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, String? category, IconData icon) {
    final selected = _selectedCategory == category;
    return FilterChip(
      selected: selected,
      label: Text(label, style: const TextStyle(fontSize: 12)),
      avatar: Icon(icon, size: 16),
      onSelected: (_) => setState(() => _selectedCategory = selected ? null : category),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme, ThemeData theme, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.errorContainer.withValues(alpha: 0.3),
              ),
              child: Icon(
                Icons.cloud_off,
                size: 40,
                color: colorScheme.error.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              ),
              child: Icon(
                Icons.history,
                size: 40,
                color: colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No recent discoveries',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Places AI has notified you about will appear here.\nStart the radar to begin discovering.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme, ThemeData theme, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(Icons.access_time, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            'Last 24 hours',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(
    BuildContext context,
    DiscoveryItem item,
    bool isLast,
    ColorScheme colorScheme,
    ThemeData theme,
    String deviceToken,
  ) {
    return Dismissible(
      key: ValueKey('recent_${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: colorScheme.error),
      ),
      onDismissed: (_) {
        context.read<RadarPreferencesProvider>().removeRecent(item.id);
      },
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 32,
              child: Column(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _categoryColor(item.category, colorScheme),
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
                child: _RecentCard(
                  item: item,
                  relativeTime: _relativeTime(item.discoveredAt),
                  deviceToken: deviceToken,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _categoryColor(String category, ColorScheme colorScheme) {
    switch (category) {
      case 'food':
        return Colors.orange.shade700;
      case 'travel_attractions':
        return Colors.blue.shade700;
      case 'essentials_transit':
        return Colors.green.shade700;
      case 'history':
        return Colors.purple.shade700;
      case 'mystery':
        return Colors.teal.shade700;
      case 'hazard':
        return Colors.red.shade700;
      default:
        return colorScheme.primary;
    }
  }
}

class _RecentCard extends StatelessWidget {
  final DiscoveryItem item;
  final String relativeTime;
  final String deviceToken;

  const _RecentCard({
    required this.item,
    required this.relativeTime,
    this.deviceToken = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final isEnglish = prefs.currentLang == LanguagePreference.en;
    final title = isEnglish ? item.title : (item.tamilTitle ?? item.title);
    final body = isEnglish ? item.body : (item.tamilBody ?? item.body);
    final displayBody = prefs.useElaborateText
        ? body
        : (body.length <= 120 ? body : '${body.substring(0, 120)}…');
    final showImage = prefs.renderImages && item.imageUrl != null;
    final categoryIcon =
        RadarPreferencesProvider.vectorIcons[item.category] ?? Icons.place;
    final isBookmarked = prefs.pinnedDiscoveryIds.contains(item.id);

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
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
                  builder: (_) => DiscoveryDetailScreen(
                    item: item,
                    deviceToken: deviceToken,
                  ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showImage)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: double.infinity,
                      height: 140,
                      child: CachedNetworkImage(
                        imageUrl: item.imageUrl!,
                        fit: BoxFit.cover,
                        httpHeaders: ImageHttp.headers,
                        memCacheWidth: 560,
                        memCacheHeight: 280,
                        placeholder: (_, __) => Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        errorWidget: (_, __, ___) => _ImageFallback(
                          category: item.category,
                          colorScheme: colorScheme,
                        ),
                      ),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(categoryIcon, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          displayBody,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        relativeTime,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      const SizedBox(height: 4),
                      IconButton(
                        icon: Icon(
                          isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                          size: 20,
                        ),
                        onPressed: () => prefs.toggleBookmark(item.id, deviceToken),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      InkWell(
                        onTap: prefs.toggleLanguage,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            prefs.currentLang.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
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
    final icon =
        RadarPreferencesProvider.vectorIcons[category] ?? Icons.place;

    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          icon,
          size: 32,
          color: colorScheme.onSurface.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}
