import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/see_sub_screen/latest_results.dart';
import 'package:official_connect/Services/exam_result_scraper.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _resultHtml = '''
<div class="stu-data stu-data2"><p>May 2026 Semester 6</p></div>
<table class="uk-table res-table">
  <tr><th>Course Code</th><th>Subject Name</th><th>Credits Earned</th><th>Credits Reg.</th><th>Grade</th></tr>
  <tr><td>IS601</td><td>Cloud Computing</td><td>4</td><td>4</td><td>A</td></tr>
</table>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'refreshing fetched result does not call the disposed WebView controller',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FirebaseFeatureFlags.setValuesForTesting(const {
        'results_regular_enabled': true,
      });
      addTearDown(() => FirebaseFeatureFlags.setValuesForTesting(const {}));

      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _FakeWebViewPlatform();
      InAppWebViewPlatform.instance = platform;
      addTearDown(() {
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });

      final sisData = SisData();
      await sisData.loadDummyData();
      addTearDown(sisData.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: sisData,
          child: const MaterialApp(
            home: LatestResultsDetails(source: ExamResultSource.regular),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Latest regular result'), findsOneWidget);
      expect(platform.controllers, hasLength(1));
      expect(platform.controllers.single.isDisposed, isTrue);
      expect(platform.controllers.single.loadCalls, 1);

      await tester.tap(find.byTooltip('Check for a newer result'));
      await tester.pumpAndSettle();

      expect(find.text('Latest regular result'), findsOneWidget);
      expect(platform.disposedControllerLoadCalls, 0);
      expect(platform.controllers, hasLength(2));
      expect(platform.controllers.last.isDisposed, isTrue);
      expect(platform.controllers.last.loadCalls, 1);
    },
  );
}

class _FakeWebViewPlatform extends InAppWebViewPlatform {
  final List<_FakeWebViewController> controllers = [];

  int get disposedControllerLoadCalls => controllers
      .where((controller) => controller.isDisposed)
      .fold(0, (total, controller) => total + controller.loadCallsAfterDispose);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) {
    final controller = _FakeWebViewController(params, this);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebViewController extends PlatformInAppWebViewController {
  _FakeWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
    this.owner,
  ) : super.implementation(params);

  final _FakeWebViewPlatform owner;
  bool isDisposed = false;
  int loadCalls = 0;
  int loadCallsAfterDispose = 0;

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    if (isDisposed) {
      loadCallsAfterDispose++;
      return;
    }
    loadCalls++;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => _resultHtml;

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {}

  @override
  void dispose({bool isKeepAlive = false}) {
    isDisposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeWebViewWidget(PlatformInAppWebViewWidgetCreationParams params)
    : super.implementation(params);

  bool _creationScheduled = false;
  InAppWebViewController? _controller;

  @override
  Widget build(BuildContext context) {
    if (!_creationScheduled) {
      _creationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller != null) return;
        final platformController = PlatformInAppWebViewController(
          const PlatformInAppWebViewControllerCreationParams(
            id: 'test-webview',
          ),
        );
        _controller = params.controllerFromPlatform!(platformController);
        params.onWebViewCreated?.call(_controller!);
        scheduleMicrotask(() {
          params.onLoadStop?.call(
            _controller!,
            WebUri('https://example.test/'),
          );
        });
      });
    }
    return const SizedBox.shrink();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller);

  @override
  void dispose() {
    _controller?.platform.dispose();
  }
}
