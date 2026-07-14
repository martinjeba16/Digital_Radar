import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:digital_radar/main.dart';
import 'package:digital_radar/providers/radar_preferences_provider.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => RadarPreferencesProvider(),
        child: const DigitalRadarApp(),
      ),
    );

    expect(find.text('Digital Radar'), findsWidgets);
  });
}
