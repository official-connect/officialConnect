import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/loading_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'leaving startup before its delay does not navigate after disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final data = SisData();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: data,
          child: const MaterialApp(home: LoadingScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const MaterialApp(home: Text('Another screen')));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('Another screen'), findsOneWidget);
      data.dispose();
    },
  );
}
