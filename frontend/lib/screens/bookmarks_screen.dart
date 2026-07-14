import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../models/language_preference.dart';
import '../providers/radar_preferences_provider.dart';
import 'discovery_detail_screen.dart';

class BookmarksScreen extends StatefulWidget {
  final String deviceToken;

  const BookmarksScreen({super.key, required this.deviceToken});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  bool _loading = false;
  String? _selectedCategory;

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await context.read<RadarPreferencesProvider>().loadBookmarks(widget.deviceToken);
    if (mounted) setState(() => _loading = false);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Widget _buildErrorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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

  List<String> _availableCategories(List<DiscoveryItem> items) {
    final cats = items.map((e) => e.category).toSet();
    return RadarPreferencesProvider.vectorIcons.keys
        .where((k) => cats.contains(k))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<RadarPreferencesProvider>();
    final pinned =
        prefs.discoveries.where((d) => prefs.pinnedDiscoveryIds.contains(d.id)).toList();
    final filtered = _selectedCategory == null
        ? pinned
        : pinned.where((d) => d.category == _selectedCategory).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookmarks'),
        actions: [
          if (pinned.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Clear all bookmarks',
                onPressed: () async {
                  for (final d in pinned) {
                    await prefs.toggleBookmark(d.id, widget.deviceToken);
                  }
                },
              ),
        ],
      ),
      body: _loading && pinned.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : prefs.bookmarksError != null && pinned.isEmpty
          ? _buildErrorState(prefs.bookmarksError!)
          : pinned.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bookmark_border,
                      size: 64,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No bookmarks yet',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the bookmark icon on any discovery to save it here',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _buildFilterChips(pinned, prefs),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _BookmarkCard(
                            item: filtered[index],
                            deviceToken: widget.deviceToken,
                          ),
                        );
                      },
                    ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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
}

class _BookmarkCard extends StatelessWidget {
  final DiscoveryItem item;
  final String deviceToken;

  const _BookmarkCard({required this.item, required this.deviceToken});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<RadarPreferencesProvider>();
    final showImage = prefs.renderImages && item.imageUrl != null;
    final isEnglish = prefs.currentLang == LanguagePreference.en;
    final displayTitle = isEnglish ? item.title : (item.tamilTitle ?? item.title);
    final displayBody =
        prefs.useElaborateText
            ? (isEnglish ? item.body : (item.tamilBody ?? item.body))
            : _summarize(isEnglish ? item.body : (item.tamilBody ?? item.body));
    final categoryIcon = RadarPreferencesProvider.vectorIcons[item.category] ?? Icons.place;

    return Card(
      clipBehavior: Clip.antiAlias,
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showImage)
              CachedNetworkImage(
                imageUrl: item.imageUrl!,
                height: 140,
                fit: BoxFit.cover,
                httpHeaders: ImageHttp.headers,
                memCacheWidth: 560,
                memCacheHeight: 280,
                placeholder: (_, __) => Container(
                  height: 140,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                errorWidget: (_, __, ___) => Container(
                  height: 140,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(
                      categoryIcon,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(categoryIcon, size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          displayTitle,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.bookmark, size: 20),
                        onPressed: () => prefs.toggleBookmark(item.id, deviceToken),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    displayBody,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        _formatTime(item.discoveredAt),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: prefs.toggleLanguage,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            prefs.currentLang.label,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summarize(String text) {
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}…';
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
