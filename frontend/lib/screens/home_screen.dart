import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../config/image_http.dart';
import '../models/discovery_item.dart';
import '../models/language_preference.dart';
import '../models/radar_activity.dart';
import '../models/radar_ui_state.dart';
import '../providers/radar_preferences_provider.dart';
import '../services/connectivity_service.dart';
import '../services/fcm_service.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../widgets/discovery_timeline.dart';
import '../widgets/radar_visualization.dart';
import 'bookmarks_screen.dart';
import 'recents_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final LocationService _location = LocationService();
  bool _tracking = false;
  bool _starting = false;
  bool _pendingGpsEnable = false;
  RadarLiveState _live = const RadarLiveState();
  final List<RadarActivityEntry> _activityLog = [];
  static const _maxLogEntries = 60;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  String? _deviceToken;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  RadarPreferencesProvider? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _location.setStatusListener(_onUiState);
    _location.setActivityListener(_onActivity);
    _location.setDiscoveryListener(_onDiscovery);
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _refreshFcmStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.consumePendingAction();
      _prefs = context.read<RadarPreferencesProvider>();
      _prefs!.onBookmarkError = _showBookmarkError;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _searchController.dispose();
    _location.dispose();
    _prefs?.onBookmarkError = null;
    super.dispose();
  }

  void _showBookmarkError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  Future<void> _refreshFcmStatus() async {
    await FcmService.verifyAndLogToken();
    if (!mounted) return;
    final token = FcmService.lastToken;
    setState(() => _deviceToken = token);
    if (token != null) {
      context.read<RadarPreferencesProvider>().loadBookmarks(token);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh bookmarks when returning from a notification action.
      final token = _deviceToken;
      if (token != null) {
        context.read<RadarPreferencesProvider>().loadBookmarks(token);
      }
      NotificationService.consumePendingAction();
      if (_pendingGpsEnable) {
        _pendingGpsEnable = false;
        unawaited(_toggle());
      }
    }
  }

  void _onUiState(RadarUiState uiState, {String? detailOverride}) {
    if (!mounted) return;
    setState(() {
      _live = _live.copyWith(
        uiState: uiState,
        headline: uiState.headline,
        detail: detailOverride ?? uiState.detailMessage,
        isError: uiState.isError,
        updatedAt: DateTime.now(),
      );
    });
  }

  void _onActivity(RadarActivityEntry entry) {
    if (!mounted) return;
    if (entry.type == RadarActivityType.found) {
      context.read<RadarPreferencesProvider>().reloadDiscoveries();
    }
    setState(() {
      _activityLog.insert(0, entry);
      if (_activityLog.length > _maxLogEntries) {
        _activityLog.removeLast();
      }
      final uiState = entry.uiState;
      _live = _live.copyWith(
        lat: entry.lat ?? _live.lat,
        lon: entry.lon ?? _live.lon,
        distanceToNextSearchM: entry.distanceToNextSearchM ?? _live.distanceToNextSearchM,
        lastScanAt: entry.type == RadarActivityType.searching ||
                entry.type == RadarActivityType.found ||
                entry.type == RadarActivityType.empty
            ? entry.time
            : _live.lastScanAt,
        uiState: uiState ?? _live.uiState,
        headline: entry.headline ?? uiState?.headline ?? _live.headline,
        detail: entry.message,
        isError: entry.type == RadarActivityType.error || uiState?.isError == true,
        updatedAt: entry.time,
      );
    });
  }

  void _onTaskData(Object data) {
    _location.handleTaskData(data);
    if (data is Map && data['discovery'] != null) {
      final raw = data['discovery'] as Map<String, dynamic>;
      if (!mounted) return;
      context.read<RadarPreferencesProvider>().addDiscovery(
        DiscoveryItem.fromJson(raw),
      );
    }
  }

  void _onDiscovery(DiscoveryItem item) {
    if (!mounted) return;
    context.read<RadarPreferencesProvider>().addDiscovery(item);
  }

  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub =
        ConnectivityService.onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      if (offline && _tracking) {
        _onActivity(
          RadarActivityEntry(
            time: DateTime.now(),
            message: 'Connection lost — radar paused',
            type: RadarActivityType.error,
            headline: RadarUiState.error.headline,
            uiState: RadarUiState.error,
          ),
        );
      } else if (!offline && _tracking) {
        _location.onConnectivityRestored();
      }
    });
  }

  Future<void> _toggle() async {
    if (_tracking) {
      await _location.stop();
      _connectivitySub?.cancel();
      setState(() {
        _tracking = false;
        _live = const RadarLiveState(uiState: RadarUiState.idle);
      });
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('GPS is still on — turn it off in settings to save battery'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () => unawaited(Geolocator.openLocationSettings()),
            ),
          ),
        );
      }
      return;
    }

    setState(() {
      _starting = true;
      _activityLog.clear();
      _live = const RadarLiveState(
        uiState: RadarUiState.starting,
        headline: 'Initializing Radar…',
        detail: 'Checking permissions and server connection…',
      );
    });

    final started = await _location.start();
    if (!mounted) return;

    if (!started) {
      final gpsOff = !await Geolocator.isLocationServiceEnabled();
      if (gpsOff) {
        _pendingGpsEnable = true;
      }
    }

    setState(() {
      _starting = false;
      _tracking = started;
      if (!started && !_live.isError) {
        _live = _live.copyWith(
          uiState: RadarUiState.error,
          headline: 'Could not start',
          isError: true,
        );
      }
    });

    if (started) {
      _listenConnectivity();
    }
  }

  Future<void> _retryChecks() async {
    if (!_tracking) {
      await _toggle();
      return;
    }
    setState(() {
      _live = _live.copyWith(
        uiState: RadarUiState.scanning,
        headline: RadarUiState.scanning.headline,
        detail: 'Re-testing connection to server…',
        isError: false,
      );
    });
    await _location.onConnectivityRestored();
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _SettingsSheet(),
    );
  }

  String _statusText(RadarLiveState live) {
    if (!_tracking) return 'Radar Offline';
    return switch (live.uiState) {
      RadarUiState.idle || RadarUiState.ready => 'Radar Offline',
      RadarUiState.starting => 'Initializing…',
      RadarUiState.monitoring => live.distanceToNextSearchM != null && live.distanceToNextSearchM! > 0
          ? 'Walk ${live.distanceToNextSearchM!.toStringAsFixed(0)}m to scan'
          : 'Monitoring…',
      RadarUiState.scanning => 'Scanning current area…',
      RadarUiState.processing => 'Analyzing discoveries…',
      RadarUiState.success => live.lastScanAt != null ? 'Scan complete' : 'Active',
      RadarUiState.empty => 'No discoveries this sweep',
      RadarUiState.error => live.detail,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final allDiscoveries = prefs.discoveries;
    final discoveries = _searchQuery.isEmpty
        ? allDiscoveries
        : allDiscoveries
            .where((d) =>
                d.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                d.body.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(colorScheme),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  final token = _deviceToken;
                  final prefs = context.read<RadarPreferencesProvider>();
                  if (token != null) {
                    await prefs.loadBookmarks(token);
                  }
                  await prefs.reloadDiscoveries();
                },
                child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverList.list(
                      children: [
                        _buildRadarSection(colorScheme),
                        const SizedBox(height: 16),
                        _buildStatusRow(colorScheme),
                        const SizedBox(height: 16),
                        _buildDiscoveriesHeader(colorScheme, allDiscoveries.length),
                        if (allDiscoveries.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          TextField(
                            controller: _searchController,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Search discoveries…',
                              hintStyle: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurface.withValues(alpha: 0.4),
                              ),
                              prefixIcon: Icon(
                                Icons.search,
                                size: 18,
                                color: colorScheme.onSurface.withValues(alpha: 0.4),
                              ),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear, size: 16),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: colorScheme.primary.withValues(alpha: 0.5),
                                ),
                              ),
                              filled: true,
                              fillColor: colorScheme.surfaceContainerLow,
                            ),
                            onChanged: (v) => setState(() => _searchQuery = v),
                          ),
                        ],
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  if (discoveries.isEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverToBoxAdapter(
                        child: DiscoveryTimeline(
                          items: discoveries,
                          onToggleBookmark: _deviceToken != null
                              ? (id) => context
                                  .read<RadarPreferencesProvider>()
                                  .toggleBookmark(id, _deviceToken!)
                              : null,
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList.builder(
                        itemCount: discoveries.length,
                        itemBuilder: (context, index) {
                          final item = discoveries[index];
                          final isLast = index == discoveries.length - 1;
                          return _buildTimelineItem(
                            context,
                            item,
                            isLast,
                            colorScheme,
                          );
                        },
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverList.list(
                      children: [
                        if (_live.isError && !_starting) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _retryChecks,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        _buildActivityConsole(colorScheme),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ],
              ),
              ),
            ),
            _buildButton(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineItem(
    BuildContext context,
    DiscoveryItem item,
    bool isLast,
    ColorScheme colorScheme,
  ) {
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
              child: _HomeTimelineCard(
                item: item,
                onToggleBookmark: _deviceToken != null
                    ? (id) => context
                        .read<RadarPreferencesProvider>()
                        .toggleBookmark(id, _deviceToken!)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !_tracking
                  ? Colors.grey
                  : _live.isError
                      ? Colors.red
                      : Colors.green,
              boxShadow: _tracking && !_live.isError
                  ? [BoxShadow(color: Colors.green.withValues(alpha: 0.5), blurRadius: 6, spreadRadius: 1)]
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Digital Radar',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (_tracking && !_live.isError)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 8,
                height: 8,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colorScheme.primary,
                ),
              ),
            ),
          const Spacer(),
          if (_deviceToken != null)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Recents',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecentsScreen(deviceToken: _deviceToken!),
                  ),
                );
              },
            ),
          if (_deviceToken != null)
            IconButton(
              icon: const Icon(Icons.bookmark_border),
              tooltip: 'Bookmarks',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BookmarksScreen(deviceToken: _deviceToken!),
                  ),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _showSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildRadarSection(ColorScheme colorScheme) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Center(
          child: RadarVisualization(
            state: _live.uiState,
            statusMessage: _live.detail,
            isTracking: _tracking && !_live.isError,
            lastScanAt: _live.lastScanAt,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow(ColorScheme colorScheme) {
    final theme = Theme.of(context);
    final statusText = _statusText(_live);
    final isActive = _tracking && !_live.isError;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isActive
            ? colorScheme.primary.withValues(alpha: 0.08)
            : colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? colorScheme.primary.withValues(alpha: 0.2)
              : colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.radar : Icons.radar,
            size: 18,
            color: isActive ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? 'Radar Active' : 'Radar Offline',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isActive ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                Text(
                  statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (_live.distanceToNextSearchM != null && _live.distanceToNextSearchM! > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.tertiary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.directions_walk, size: 12, color: colorScheme.tertiary),
                  const SizedBox(width: 4),
                  Text(
                    '${_live.distanceToNextSearchM!.toStringAsFixed(0)}m',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDiscoveriesHeader(ColorScheme colorScheme, int count) {
    final theme = Theme.of(context);
    final prefs = context.watch<RadarPreferencesProvider>();
    return Row(
      children: [
        Icon(Icons.explore, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          'Discoveries',
          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (count > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
        const Spacer(),
        if (count > 0)
          TextButton.icon(
            onPressed: prefs.clearDiscoveries,
            icon: const Icon(Icons.delete_sweep, size: 16),
            label: const Text('Clear', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
      ],
    );
  }

  Widget _buildActivityConsole(ColorScheme colorScheme) {
    final theme = Theme.of(context);
    if (_activityLog.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Icon(Icons.terminal, size: 14, color: colorScheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(width: 6),
            Text(
              'System Console',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${_activityLog.length}',
                style: TextStyle(
                  fontSize: 10,
                  color: colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(6),
              itemCount: _activityLog.length,
              itemBuilder: (context, index) {
                return _buildActivityTile(_activityLog[index], colorScheme);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityTile(RadarActivityEntry entry, ColorScheme colorScheme) {
    final (icon, color) = switch (entry.type) {
      RadarActivityType.gps => (Icons.my_location, Colors.blue.shade700),
      RadarActivityType.waiting => (Icons.directions_walk, Colors.orange.shade700),
      RadarActivityType.searching => (Icons.search, Colors.indigo.shade700),
      RadarActivityType.found => (Icons.place, Colors.green.shade700),
      RadarActivityType.empty => (Icons.location_off, Colors.grey.shade700),
      RadarActivityType.error => (Icons.error_outline, Colors.red.shade700),
      RadarActivityType.info => (Icons.info_outline, Colors.blueGrey.shade700),
    };
    final textColor = colorScheme.onSurface.withValues(alpha: 0.6);
    final timeColor = colorScheme.onSurface.withValues(alpha: 0.3);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: textColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _formatTime(entry.time),
            style: TextStyle(fontSize: 9, fontFamily: 'monospace', color: timeColor),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _buildButton(ColorScheme colorScheme) {
    final isGreen = _tracking && !_live.isError;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          onPressed: _starting ? null : _toggle,
          style: FilledButton.styleFrom(
            backgroundColor: isGreen ? Colors.red.shade700 : colorScheme.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: Icon(_starting ? Icons.hourglass_top : (_tracking ? Icons.stop : Icons.play_arrow)),
          label: Text(
            _starting
                ? 'Starting…'
                : (_tracking ? 'Stop Radar' : 'Start Radar'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final prefs = context.watch<RadarPreferencesProvider>();
    final vectors = prefs.activeRadarVectors;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Settings',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              title: const Text('Deep Dark Mode'),
              subtitle: const Text('OLED-optimized dark theme'),
              value: prefs.isDarkMode,
              onChanged: (_) => prefs.toggleDarkMode(),
              secondary: Icon(prefs.isDarkMode ? Icons.dark_mode : Icons.light_mode),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Display',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Images'),
              subtitle: const Text('Show images in discovery cards'),
              value: prefs.renderImages,
              onChanged: (_) => prefs.toggleRenderImages(),
              secondary: Icon(prefs.renderImages ? Icons.image : Icons.image_outlined),
              dense: true,
            ),
            SwitchListTile(
              title: const Text('Elaborate Text'),
              subtitle: const Text('Show full descriptions instead of summaries'),
              value: prefs.useElaborateText,
              onChanged: (_) => prefs.toggleElaborateText(),
              secondary: Icon(prefs.useElaborateText ? Icons.article : Icons.article_outlined),
              dense: true,
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Notifications',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Push Notifications'),
              subtitle: const Text('Receive discovery alerts'),
              value: prefs.notificationsEnabled,
              onChanged: (_) => prefs.toggleNotificationsEnabled(),
              secondary: Icon(prefs.notificationsEnabled ? Icons.notifications_active : Icons.notifications_off),
              dense: true,
            ),
            SwitchListTile(
              title: const Text('Notification Images'),
              subtitle: const Text('Show images in push notifications'),
              value: prefs.notificationImages,
              onChanged: (_) => prefs.toggleNotificationImages(),
              secondary: Icon(prefs.notificationImages ? Icons.image : Icons.image_outlined),
              dense: true,
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Scan Radius',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Center(
              child: SegmentedButton<ScanRadiusHint>(
                segments: ScanRadiusHint.values
                    .map(
                      (h) => ButtonSegment<ScanRadiusHint>(
                        value: h,
                        label: Text(h.label, style: const TextStyle(fontSize: 12)),
                        icon: Icon(
                          h == ScanRadiusHint.tight
                              ? Icons.radio_button_unchecked
                              : h == ScanRadiusHint.normal
                                  ? Icons.circle
                                  : Icons.circle_outlined,
                          size: 18,
                        ),
                      ),
                    )
                    .toList(),
                selected: {prefs.radiusHint},
                onSelectionChanged: (s) => prefs.setRadiusHint(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
                ),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Scan Vectors',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: vectors.entries.map((entry) {
                  final label = RadarPreferencesProvider.vectorLabels[entry.key] ?? entry.key;
                  final icon = RadarPreferencesProvider.vectorIcons[entry.key] ?? Icons.place;
                  return FilterChip(
                    label: Text(label, style: const TextStyle(fontSize: 13)),
                    avatar: Icon(icon, size: 18),
                    selected: entry.value,
                    onSelected: (_) => prefs.toggleVector(entry.key),
                    visualDensity: VisualDensity.comfortable,
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Notification Frequency',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Center(
              child: SegmentedButton<NotificationFrequency>(
                segments: NotificationFrequency.values
                    .map(
                      (f) => ButtonSegment<NotificationFrequency>(
                        value: f,
                        label: Text(f.label, style: const TextStyle(fontSize: 12)),
                        tooltip: f.description,
                      ),
                    )
                    .toList(),
                selected: {prefs.notificationFrequency},
                onSelectionChanged: (s) => prefs.setNotificationFrequency(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  padding: WidgetStateProperty.all(
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 12),
              child: Text(
                prefs.notificationFrequency.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About Digital Radar'),
              subtitle: const Text('v0.1.0'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _HomeTimelineCard extends StatelessWidget {
  final DiscoveryItem item;
  final void Function(String id)? onToggleBookmark;

  const _HomeTimelineCard({
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
    final title = isEnglish ? item.title : (item.tamilTitle ?? item.title);
    final body = isEnglish ? item.body : (item.tamilBody ?? item.body);
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
                        placeholder: (_, __) => _HomeTimelineFallback(colorScheme),
                        errorWidget: (_, __, ___) => _HomeTimelineFallback(colorScheme),
                      )
                    : _HomeTimelineFallback(colorScheme),
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

class _HomeTimelineFallback extends StatelessWidget {
  final ColorScheme colorScheme;
  const _HomeTimelineFallback(this.colorScheme);

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
