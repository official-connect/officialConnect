import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Classes/previous_result.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/student_home/results_screen/see_sub_screen/see_details/see_details.dart';
import 'package:official_connect/Services/exam_result_scraper.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _ResultStage { loading, captcha, submitting, result, error }

class LatestResultsDetails extends StatefulWidget {
  const LatestResultsDetails({super.key, required this.source});

  final ExamResultSource source;

  @override
  State<LatestResultsDetails> createState() => _LatestResultsDetailsState();
}

class _LatestResultsDetailsState extends State<LatestResultsDetails> {
  final TextEditingController _captchaController = TextEditingController();
  InAppWebViewController? _webController;
  _ResultStage _stage = _ResultStage.loading;
  Uint8List? _captchaBytes;
  PreviousResult? _result;
  String? _error;
  String? _notice;
  bool _submitted = false;
  bool _cacheChecked = false;
  String _usn = '';
  Stopwatch? _fetchWatch;

  String get _sourceName =>
      widget.source == ExamResultSource.regular ? 'regular' : 'supplementary';

  String get _cacheKey =>
      'exam-result:${widget.source.name}:${_usn.toUpperCase()}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _usn = Provider.of<SisData>(context, listen: false).usn.trim();
      _loadCachedResult();
    });
  }

  @override
  void dispose() {
    _captchaController.dispose();
    super.dispose();
  }

  Future<void> _loadCachedResult() async {
    final cached = (await SharedPreferences.getInstance()).getString(_cacheKey);
    if (!mounted) return;
    if (cached != null) {
      try {
        setState(() {
          _result = _resultFromJson(jsonDecode(cached));
          _stage = _ResultStage.result;
          _cacheChecked = true;
        });
        return;
      } catch (_) {
        // A stale cache should never block a fresh fetch.
      }
    }
    if (mounted) setState(() => _cacheChecked = true);
    await _startFetch();
  }

  Future<void> _startFetch() async {
    if (!FirebaseFeatureFlags.resultSourceEnabled(_sourceName)) {
      await SyncDiagnostics.recordResult(
        source: _sourceName,
        outcome: 'disabled',
      );
      if (mounted) {
        setState(() {
          _notice =
              'This result source is temporarily unavailable. Showing your saved result.';
          if (_result == null) {
            _stage = _ResultStage.error;
            _error = 'This result source is temporarily unavailable.';
          } else {
            _stage = _ResultStage.result;
          }
        });
      }
      return;
    }
    _fetchWatch = Stopwatch()..start();
    _submitted = false;
    _captchaController.clear();
    if (mounted) {
      setState(() {
        _stage = _ResultStage.loading;
        _captchaBytes = null;
        _error = null;
        _notice = null;
      });
    }
    final controller = _webController;
    if (controller != null) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(widget.source.pageUrl)),
        );
      } on MissingPluginException {
        await _showWebViewUnavailable();
      } on PlatformException {
        await _showWebViewUnavailable();
      }
    }
  }

  Future<void> _showWebViewUnavailable() async {
    if (!mounted) return;
    setState(() {
      _stage = _ResultStage.error;
      _error = 'Results could not be opened on this device. Please try again.';
    });
    await SyncDiagnostics.recordResult(
      source: _sourceName,
      outcome: 'error',
      durationMs: _fetchWatch?.elapsedMilliseconds,
    );
  }

  Future<void> _prepareCaptcha(InAppWebViewController controller) async {
    final usn = jsonEncode(_usn.toUpperCase());
    final selector = jsonEncode(widget.source.captchaSelector);
    await controller.evaluateJavascript(
      source:
          '''
      (function() {
        const usn = document.querySelector('#usn, input[name="usn"]');
        if (usn) {
          usn.value = $usn;
          usn.dispatchEvent(new Event('input', {bubbles: true}));
          usn.dispatchEvent(new Event('change', {bubbles: true}));
        }
        const image = document.querySelector($selector);
        if (!image) return;
        const sendImage = function() {
          try {
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth || image.width;
            canvas.height = image.naturalHeight || image.height;
            canvas.getContext('2d').drawImage(image, 0, 0);
            window.flutter_inappwebview.callHandler(
              'officialConnectExamCaptcha', canvas.toDataURL('image/png'));
          } catch (error) {
            window.flutter_inappwebview.callHandler(
              'officialConnectExamCaptchaError', String(error));
          }
        };
        if (image.complete && image.naturalWidth) sendImage();
        else image.addEventListener('load', sendImage, {once: true});
      })();
    ''',
    );
  }

  Future<void> _submitCaptcha() async {
    final value = _captchaController.text.trim();
    if (value.isEmpty || _webController == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _stage = _ResultStage.submitting;
      _error = null;
    });
    _submitted = true;
    final selector = jsonEncode(widget.source.captchaInputSelector);
    final encodedValue = jsonEncode(value);
    await _webController!.evaluateJavascript(
      source:
          '''
      (function() {
        const input = document.querySelector($selector);
        if (!input) return false;
        input.value = $encodedValue;
        input.dispatchEvent(new Event('input', {bubbles: true}));
        input.dispatchEvent(new Event('change', {bubbles: true}));
        const form = input.form || document.querySelector('form');
        if (!form) return false;
        if (typeof form.requestSubmit === 'function') form.requestSubmit();
        else form.submit();
        return true;
      })();
    ''',
    );
  }

  Future<void> _refreshCaptcha() async {
    _captchaController.clear();
    setState(() {
      _captchaBytes = null;
      _stage = _ResultStage.loading;
      _error = null;
    });
    final imageSelector = jsonEncode(widget.source.captchaSelector);
    final reload = widget.source == ExamResultSource.regular
        ? "document.querySelector('#reloadCaptcha')?.click();"
        : "if (typeof reloadCapthcha === 'function') reloadCapthcha(0);";
    await _webController?.evaluateJavascript(
      source:
          '''
      (function() {
        $reload
        setTimeout(function() {
          const image = document.querySelector($imageSelector);
          if (!image) { location.reload(); return; }
          const canvas = document.createElement('canvas');
          canvas.width = image.naturalWidth || image.width;
          canvas.height = image.naturalHeight || image.height;
          canvas.getContext('2d').drawImage(image, 0, 0);
          window.flutter_inappwebview.callHandler(
            'officialConnectExamCaptcha', canvas.toDataURL('image/png'));
        }, 700);
      })();
    ''',
    );
  }

  Future<void> _handleLoadedPage(InAppWebViewController controller) async {
    final html = (await controller.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    )).toString();
    try {
      final result = ExamResultScraper.parse(html, widget.source);
      await (await SharedPreferences.getInstance()).setString(
        _cacheKey,
        jsonEncode(_resultToJson(result)),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _ResultStage.result;
      });
      await SyncDiagnostics.recordResult(
        source: _sourceName,
        outcome: 'success',
        durationMs: _fetchWatch?.elapsedMilliseconds,
      );
      return;
    } on ExamResultParseException {
      // Landing and failed-challenge pages legitimately have no result table.
    }

    if (_submitted) {
      _submitted = false;
      _captchaController.clear();
      if (mounted) {
        setState(() {
          _error =
              'That security code was not accepted. Please try the new one.';
        });
      }
    }
    await _prepareCaptcha(controller);
  }

  Map<String, dynamic> _resultToJson(PreviousResult result) => {
    'cgpa': result.cgpa,
    'creditsEarned': result.creditsEarned,
    'creditsRegistered': result.creditsRegistered,
    'sgpa': result.sgpa,
    'term': result.term,
    'semesterNumber': result.semesterNumber,
    'results': result.results
        .map(
          (subject) => {
            'courseCode': subject.courseCode,
            'subjectName': subject.subjectName,
            'creditsEarned': subject.creditsEarned,
            'creditsRegistered': subject.creditsRegistered,
            'gpa': subject.gpa,
            'grade': subject.grade,
          },
        )
        .toList(),
  };

  PreviousResult _resultFromJson(Map<String, dynamic> value) => PreviousResult(
    cgpa: value['cgpa'],
    creditsEarned: value['creditsEarned'],
    creditsRegistered: value['creditsRegistered'],
    sgpa: value['sgpa'],
    term: value['term'],
    semesterNumber: value['semesterNumber'],
    results: (value['results'] as List)
        .map(
          (item) => Subject(
            courseCode: item['courseCode'],
            subjectName: item['subjectName'],
            creditsEarned: item['creditsEarned'],
            creditsRegistered: item['creditsRegistered'],
            gpa: item['gpa'],
            grade: item['grade'],
          ),
        )
        .toList(),
  );

  @override
  Widget build(BuildContext context) {
    final sisData = Provider.of<SisData>(context);
    if (_stage == _ResultStage.result && _result != null) {
      return Stack(
        children: [
          ResultsDetails(
            previousResult: _result!,
            contextLabel: widget.source.label,
            onRefresh: _startFetch,
          ),
          if (_notice != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                child: Material(
                  color: const Color(0xff32383b),
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final foreground = sisData.darkMode ? Colors.white : Colors.black87;
    return Scaffold(
      backgroundColor: sisData.darkMode
          ? Colors.black
          : NeumorphicColors.background,
      body: Stack(
        children: [
          if (_cacheChecked)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri('about:blank')),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    thirdPartyCookiesEnabled: true,
                  ),
                  onWebViewCreated: (controller) async {
                    _webController = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'officialConnectExamCaptcha',
                      callback: (arguments) {
                        if (arguments.isEmpty || !mounted) return;
                        final data = arguments.first.toString();
                        final comma = data.indexOf(',');
                        if (comma < 0) return;
                        setState(() {
                          _captchaBytes = base64Decode(
                            data.substring(comma + 1),
                          );
                          _stage = _ResultStage.captcha;
                        });
                      },
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'officialConnectExamCaptchaError',
                      callback: (_) {
                        if (!mounted) return;
                        setState(() {
                          _stage = _ResultStage.error;
                          _error = 'The security image could not be loaded.';
                        });
                        SyncDiagnostics.recordResult(
                          source: _sourceName,
                          outcome: 'error',
                          durationMs: _fetchWatch?.elapsedMilliseconds,
                        );
                      },
                    );
                    if (_stage != _ResultStage.result) await _startFetch();
                  },
                  onLoadStop: (controller, _) => _handleLoadedPage(controller),
                  onJsAlert: (controller, request) async {
                    _submitted = false;
                    _captchaController.clear();
                    final portalMessage = request.message?.trim() ?? '';
                    final isRejectedCode =
                        portalMessage.toLowerCase().contains('captcha') ||
                        portalMessage.toLowerCase().contains('security code');
                    if (mounted) {
                      setState(() {
                        _captchaBytes = null;
                        _stage = _ResultStage.loading;
                        _error = isRejectedCode || portalMessage.isEmpty
                            ? 'That security code was not accepted. Please try the new one.'
                            : portalMessage;
                      });
                    }
                    Future<void>.delayed(
                      const Duration(milliseconds: 100),
                      controller.reload,
                    );
                    return JsAlertResponse(
                      handledByClient: true,
                      action: JsAlertResponseAction.CONFIRM,
                    );
                  },
                  onReceivedError: (_, request, __) {
                    if (request.isForMainFrame != true) return;
                    if (!mounted) return;
                    setState(() {
                      _stage = _ResultStage.error;
                      _error =
                          'The examination results site could not be reached.';
                    });
                    SyncDiagnostics.recordResult(
                      source: _sourceName,
                      outcome: 'network_error',
                      durationMs: _fetchWatch?.elapsedMilliseconds,
                    );
                  },
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.chevron_left, color: foreground),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: Neumorphic(
                          style: CustomTheme.neumorphicStyle(context),
                          padding: const EdgeInsets.all(24),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 430),
                            child: _buildContent(context, foreground),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color foreground) {
    if (_stage == _ResultStage.loading || _stage == _ResultStage.submitting) {
      return Column(
        children: [
          const CircularProgressIndicator(color: Color(0xffba3237)),
          const SizedBox(height: 22),
          Text(
            _stage == _ResultStage.submitting
                ? 'Checking your result'
                : 'Opening examination results',
            textAlign: TextAlign.center,
            style: CustomTheme.buttonTrailing(context),
          ),
          const SizedBox(height: 8),
          Text(
            'Your USN is filled automatically.',
            textAlign: TextAlign.center,
            style: CustomTheme.textStyle(context).copyWith(color: foreground),
          ),
        ],
      );
    }

    if (_stage == _ResultStage.error) {
      return Column(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Color(0xffba3237),
          ),
          const SizedBox(height: 16),
          Text(_error ?? 'Unable to load results', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _startFetch,
            child: const Text('Try again'),
          ),
        ],
      );
    }

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.fact_check_outlined,
            size: 48,
            color: Color(0xffba3237),
          ),
          const SizedBox(height: 14),
          Text(
            widget.source.label,
            textAlign: TextAlign.center,
            style: CustomTheme.buttonTrailing(context),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the security code shown by the examination site. This is the only manual step.',
            textAlign: TextAlign.center,
            style: CustomTheme.textStyle(
              context,
            ).copyWith(color: foreground.withValues(alpha: 0.68), height: 1.4),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xffba3237)),
            ),
          ],
          const SizedBox(height: 20),
          if (_captchaBytes != null)
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Image.memory(
                  _captchaBytes!,
                  height: 55,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          TextButton.icon(
            onPressed: _refreshCaptcha,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Show a different code'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('exam-captcha'),
            controller: _captchaController,
            style: CustomTheme.buttonTitle(context).copyWith(color: foreground),
            cursorColor: CustomTheme.accent,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Security code',
              labelStyle: TextStyle(color: foreground.withValues(alpha: 0.72)),
              floatingLabelStyle: const TextStyle(color: CustomTheme.accent),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: foreground.withValues(alpha: 0.38),
                ),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: CustomTheme.accent, width: 2),
              ),
            ),
            onSubmitted: (_) => _submitCaptcha(),
          ),
          const SizedBox(height: 18),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xffba3237),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            onPressed: _submitCaptcha,
            child: const Text('View result'),
          ),
        ],
      ),
    );
  }
}
