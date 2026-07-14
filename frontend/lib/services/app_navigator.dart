import 'package:flutter/material.dart';

/// Global navigator so notification action handlers (which have no BuildContext)
/// can open screens after the user taps Bookmark / Read More / Navigate.
class AppNavigator {
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();

  static NavigatorState? get state => key.currentState;

  static BuildContext? get context => key.currentContext;

  /// Pending deep-link from a notification action that fired before the
  /// navigator was ready (cold start). Consumed once by [HomeScreen].
  static Map<String, dynamic>? pendingAction;

  static void setPending(Map<String, dynamic> action) {
    pendingAction = action;
  }

  static Map<String, dynamic>? takePending() {
    final action = pendingAction;
    pendingAction = null;
    return action;
  }
}
