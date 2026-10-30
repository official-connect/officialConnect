import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:official_connect/Services/portal_session.dart';
import 'package:official_connect/Services/portal_scraper.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:provider/provider.dart';

enum PortalLoginOutcome {
  success,
  cancelled,
  timeout,
  networkError,
  updateError,
  disabled,
}

/// Keeps a browser-backed platform view mounted without allowing Android's
/// platform-view compositor to paint a full-screen portal behind native UI.
/// The full viewport is used only after the user explicitly asks to see it.
class PortalBrowserViewport extends StatelessWidget {
  const PortalBrowserViewport({
    super.key,
    required this.hidden,
    required this.child,
  });

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: hidden ? -2 : 0,
      top: hidden ? -2 : 0,
      right: hidden ? null : 0,
      bottom: hidden ? null : 0,
      width: hidden ? 1 : null,
      height: hidden ? 1 : null,
      child: IgnorePointer(ignoring: hidden, child: child),
    );
  }
}

class PortalLoginScreen extends StatefulWidget {
  const PortalLoginScreen({
    super.key,
    this.initialUsn,
    this.initialDob,
    this.initialVerificationType,
    this.initialVerificationValue,
    this.reuseSession = false,
    this.silent = false,
    this.onFinished,
    this.onOutcome,
    this.browserForTesting,
    this.browserBuilderForTesting,
  });

  final String? initialUsn;
  final String? initialDob;
  final String? initialVerificationType;
  final String? initialVerificationValue;
  final bool reuseSession;

  /// Runs the portal login and scrape off-screen (transparent route). The
  /// caller stays visible and shows its own completion notification.
  final bool silent;

  /// Lets background refresh run in a pointer-transparent overlay instead of
  /// pushing a modal route over the app. Interactive login flows continue to
  /// use the Navigator when no callback is supplied.
  final ValueChanged<bool>? onFinished;

  /// Bounded terminal result for callers that need to distinguish outcomes.
  /// [onFinished] remains available for existing boolean callers.
  final ValueChanged<PortalLoginOutcome>? onOutcome;

  @visibleForTesting
  final Widget? browserForTesting;

  @visibleForTesting
  final Widget Function({
    required ValueChanged<Uri?> onLoadStop,
    required ValueChanged<bool> onReceivedError,
    required VoidCallback onNavigationStart,
    required ValueChanged<Object> onBrowserFailure,
    required void Function({
      required bool isMainFrame,
      required int? statusCode,
    })
    onReceivedHttpError,
  })?
  browserBuilderForTesting;

  @override
  State<PortalLoginScreen> createState() => _PortalLoginScreenState();
}

class _PortalLoginScreenState extends State<PortalLoginScreen>
    with WidgetsBindingObserver {
  late final PortalSession _session = PortalSession();
  bool _scrapeStarted = false;
  bool _finished = false;
  bool _deadlineReached = false;
  bool _initialPageReached = false;
  bool _initialNavigationStarted = false;
  bool _showPortal = false;
  String _stage = 'Getting things ready';
  String _detail = 'This usually takes a few seconds.';
  String? _error;
  final Stopwatch _flowWatch = Stopwatch();
  Timer? _attentionTimer;
  Timer? _hardTimeoutTimer;
  Timer? _initialConnectionTimer;
  bool _flowStarted = false;
  bool _terminalOutcomeRecorded = false;
  Future<void>? _startEvent;
  final String _flowId = DateTime.now().microsecondsSinceEpoch.toRadixString(
    36,
  );
  String _diagnosticStageValue = 'getting_ready';
  String _failureSection = 'dashboard';
  String _failureStep = 'authenticate';
  bool _cacheOperation = false;
  bool _hadCachedData = false;
  final Set<String> _recordedAttention = {};

  String get _diagnosticStage => _diagnosticStageValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hadCachedData = Provider.of<SisData>(context, listen: false).hasData;
    // Include platform-view startup in the deadline, not only page loading.
    _flowWatch.start();
    _flowStarted = true;
    _startEvent = SyncDiagnostics.recordLoginStarted(
      refresh: widget.reuseSession,
      flowId: _flowId,
    );
    _attentionTimer = Timer(const Duration(seconds: 45), () {
      unawaited(_recordAttention('timeout'));
    });
    _hardTimeoutTimer = Timer(const Duration(seconds: 75), _handleDeadline);
  }

  bool _isInitialPortalPage(Uri? uri) =>
      uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == PortalSession.loginUri.host.toLowerCase() &&
      uri.port == PortalSession.loginUri.port &&
      uri.path.startsWith('/newparents/');

  void _markInitialPageReached(Uri? uri) {
    if (_finished || _deadlineReached || !_isInitialPortalPage(uri)) return;
    _initialPageReached = true;
    _initialConnectionTimer?.cancel();
    _initialConnectionTimer = null;
  }

  void _stopDeadlineTimers() {
    _attentionTimer?.cancel();
    _hardTimeoutTimer?.cancel();
    _initialConnectionTimer?.cancel();
  }

  void _handleInitialConnectionDeadline() {
    if (!_initialNavigationStarted) return;
    _handleInitialConnectionFailure(
      TimeoutException('Initial portal page deadline exceeded'),
    );
  }

  void _startInitialConnectionDeadline() {
    if (_finished ||
        !mounted ||
        _deadlineReached ||
        _initialNavigationStarted ||
        _initialPageReached) {
      return;
    }
    _initialNavigationStarted = true;
    _initialConnectionTimer?.cancel();
    _initialConnectionTimer = Timer(
      const Duration(seconds: 15),
      _handleInitialConnectionDeadline,
    );
  }

  void _handleInitialConnectionFailure(Object error) {
    if (_finished ||
        !mounted ||
        _deadlineReached ||
        !_initialNavigationStarted ||
        _initialPageReached) {
      return;
    }
    _deadlineReached = true;
    _stopDeadlineTimers();
    _reportFailure(error);
    unawaited(_recordFinish(error is TimeoutException ? 'timeout' : 'error'));
    if (error is TimeoutException) unawaited(_recordAttention('timeout'));
    if (widget.silent) {
      final outcome = switch (error) {
        TimeoutException() => PortalLoginOutcome.timeout,
        SocketException() => PortalLoginOutcome.networkError,
        _ => PortalLoginOutcome.updateError,
      };
      _finish(false, outcome: outcome);
      return;
    }
    setState(() {
      _showPortal = false;
      _error = 'connection';
      _stage = 'Unable to connect to the website';
      _detail =
          'The website is taking too long to respond. Please try again later.';
      if (_hadCachedData) {
        _detail += ' Your saved information is still available.';
      }
    });
  }

  void _handleInitialHttpError({
    required bool isMainFrame,
    required int? statusCode,
  }) {
    if (!isMainFrame ||
        statusCode == null ||
        statusCode < 400 ||
        !_initialNavigationStarted ||
        _initialPageReached ||
        _deadlineReached ||
        _finished) {
      return;
    }
    _handleInitialConnectionFailure(
      PortalRequestException(PortalSession.loginUri, 'HTTP error'),
    );
  }

  void _handleDeadline() {
    if (_finished || !mounted || _deadlineReached) return;
    _deadlineReached = true;
    _stopDeadlineTimers();
    unawaited(_recordAttention('timeout'));
    unawaited(_recordFinish('timeout'));
    _reportFailure(TimeoutException('Sync deadline exceeded'));
    if (widget.silent) {
      _finish(false, outcome: PortalLoginOutcome.timeout);
    } else {
      setState(() {
        _showPortal = false;
        _error = 'timeout';
        _stage = !_initialPageReached
            ? 'Unable to connect to the website'
            : _scrapeStarted
            ? 'Update took too long'
            : 'Sign-in took too long';
        _detail = !_initialPageReached
            ? 'The website is taking too long to respond. Please try again later.'
            : _scrapeStarted
            ? 'Please try again in a little while.'
            : 'Please try signing in again.';
        if (_hadCachedData) {
          _detail += ' Your saved information is still available.';
        }
      });
    }
  }

  void _reportFailure(Object error) {
    final reason =
        _cacheOperation &&
            _failureStep == 'persist' &&
            error is! TimeoutException
        ? 'cache_write'
        : portalFailureReason(error);
    if (_cacheOperation) {
      unawaited(
        SyncDiagnostics.recordOperationalFailure(
          operation: 'cache',
          stage: _diagnosticStage,
          reason: reason,
          exceptionKind: portalFailureKind(error),
          refresh: widget.reuseSession,
          section: _failureSection,
          step: _failureStep,
          durationMs: _flowWatch.elapsedMilliseconds,
          hasCachedData: _hadCachedData,
        ),
      );
    } else {
      unawaited(
        SyncDiagnostics.recordFailure(
          refresh: widget.reuseSession,
          stage: _diagnosticStage,
          reason: reason,
          exceptionKind: portalFailureKind(error),
          section: _failureSection,
          step: _failureStep,
          durationMs: _flowWatch.elapsedMilliseconds,
          hasCachedData: _hadCachedData,
        ),
      );
    }
  }

  Future<void> _recordAttention(String reason) async {
    if (!_flowStarted || _finished || !_recordedAttention.add(reason)) return;
    await SyncDiagnostics.recordLoginAttention(
      reason: reason,
      stage: _diagnosticStage,
      refresh: widget.reuseSession,
      durationMs: _flowWatch.elapsedMilliseconds,
    );
  }

  Future<void> _recordFinish(String outcome) async {
    if (_terminalOutcomeRecorded) return;
    _terminalOutcomeRecorded = true;
    await _startEvent;
    await SyncDiagnostics.recordLoginFinished(
      outcome: outcome,
      refresh: widget.reuseSession,
      durationMs: _flowWatch.elapsedMilliseconds,
      flowId: _flowId,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_recordAttention('backgrounded'));
      if (widget.silent && !_finished) {
        unawaited(_recordFinish('cancelled'));
        _finish(false, outcome: PortalLoginOutcome.cancelled);
      }
    }
  }

  @override
  void dispose() {
    _stopDeadlineTimers();
    WidgetsBinding.instance.removeObserver(this);
    if (_flowStarted && !_finished) {
      unawaited(_recordAttention('disposed'));
      unawaited(_recordFinish('cancelled'));
      _finished = true;
      final finishedCallback = widget.onFinished;
      final outcomeCallback = widget.onOutcome;
      finishedCallback?.call(false);
      outcomeCallback?.call(PortalLoginOutcome.cancelled);
    }
    super.dispose();
  }

  void _finish(bool result, {required PortalLoginOutcome outcome}) {
    if (_finished) return;
    _stopDeadlineTimers();
    _finished = true;
    final callback = widget.onFinished;
    final outcomeCallback = widget.onOutcome;
    if (callback != null) {
      callback(result);
    } else if (outcomeCallback == null && mounted) {
      Navigator.of(context).pop(result);
    }
    outcomeCallback?.call(outcome);
  }

  void _updateStage(String stage, {String? detail}) {
    assert(() {
      debugPrint('Portal timing: ${_flowWatch.elapsedMilliseconds}ms - $stage');
      return true;
    }());
    if (!mounted || _finished || _deadlineReached) return;
    setState(() {
      _stage = stage;
      if (detail != null) _detail = detail;
    });
  }

  Future<void> _handleBrowserFailure(Object error) async {
    if (_finished || _deadlineReached || _scrapeStarted) return;
    _initialConnectionTimer?.cancel();
    _initialConnectionTimer = null;
    _reportFailure(error);
    if (!mounted || _finished || _deadlineReached) return;
    if (widget.silent) {
      unawaited(_recordFinish('error'));
      _finish(false, outcome: PortalLoginOutcome.updateError);
      return;
    }
    setState(() {
      _diagnosticStageValue = 'needs_attention';
      _error = 'Sign-in could not continue. Please try again.';
      _stage = 'Update needs attention';
      _detail = 'Anything already available will remain visible.';
    });
  }

  Future<void> _scrapeAndCache() async {
    if (_scrapeStarted || _deadlineReached) return;
    _scrapeStarted = true;
    final scrapeWatch = Stopwatch()..start();
    if (!FirebaseFeatureFlags.portalSyncEnabled) {
      unawaited(_recordFinish('disabled'));
      _finish(false, outcome: PortalLoginOutcome.disabled);
      return;
    }
    _diagnosticStageValue = 'scraping';
    _updateStage('Login complete', detail: 'Updating your information.');
    if (!mounted || _finished) return;
    final sisData = Provider.of<SisData>(context, listen: false);
    Future<void> applyData(
      Map<String, dynamic> data, {
      String section = 'unknown',
    }) async {
      if (!mounted || _finished || _deadlineReached) return;
      _cacheOperation = true;
      _failureSection = section;
      _failureStep = 'apply';
      await sisData.applyPortalData(
        data,
        widget.initialUsn ?? '',
        widget.initialDob ?? '',
        onStage: (step) => _failureStep = step,
      );
      _cacheOperation = false;
    }

    try {
      // The portal currently rejects replay of its browser session from AWS.
      // Scraping directly in this authenticated WebView avoids that failed
      // network hop and keeps credentials on the device.
      final data = await PortalScraper(
        _session,
        onProgress: (stage) => _updateStage(stage),
        isActive: () => mounted && !_finished && !_deadlineReached,
        onDiagnosticStep: (section, step) {
          _failureSection = section;
          _failureStep = step;
        },
        onMarksReady: (data) async {
          if (!mounted ||
              _finished ||
              !widget.reuseSession ||
              !sisData.hasData) {
            return;
          }
          await applyData(data, section: 'marks');
        },
        onAttendanceReady: (data) async {
          if (!mounted ||
              _finished ||
              !widget.reuseSession ||
              !sisData.hasData) {
            return;
          }
          await applyData(data, section: 'attendance');
          assert(() {
            debugPrint(
              'Portal attendance available in ${scrapeWatch.elapsedMilliseconds}ms',
            );
            return true;
          }());
        },
      ).scrapeAll();
      if (!mounted || _finished || _deadlineReached) return;
      assert(() {
        debugPrint(
          'Portal scraper sections: '
          'attendance=${(data['attendance'] as List?)?.length ?? 0}, '
          'marks=${(data['marks'] as List?)?.length ?? 0}, '
          'results=${(data['prevResults'] as List?)?.length ?? 0}, '
          'fees=${(data['fees'] as List?)?.length ?? 0}',
        );
        return true;
      }());
      final hasUsefulSections =
          data['courseSmall'] != null ||
          (data['attendance'] is List &&
              (data['attendance'] as List).isNotEmpty) ||
          (data['marks'] is List && (data['marks'] as List).isNotEmpty) ||
          (data['prevResults'] is List &&
              (data['prevResults'] as List).isNotEmpty) ||
          (data['fees'] is List && (data['fees'] as List).isNotEmpty);
      if (!hasUsefulSections) {
        throw PortalRequestException(
          PortalSession.dashboardUri,
          'scraper returned incomplete portal data',
        );
      }
      _diagnosticStageValue = 'finishing';
      await applyData(data);
      if (!mounted || _finished || _deadlineReached) return;
      unawaited(
        SyncDiagnostics.recordSummary(
          sisData.syncMetadata,
          refresh: widget.reuseSession,
        ),
      );
      unawaited(_recordFinish('success'));
      scrapeWatch.stop();
      _updateStage('Finishing up');
      assert(() {
        debugPrint(
          'Portal scraper: cache updated successfully in '
          '${scrapeWatch.elapsedMilliseconds}ms; total '
          '${_flowWatch.elapsedMilliseconds}ms',
        );
        return true;
      }());
      if (mounted) {
        _finish(true, outcome: PortalLoginOutcome.success);
      }
    } catch (error) {
      if (_finished || _deadlineReached || !mounted) return;
      _reportFailure(error);
      unawaited(_recordFinish('error'));
      debugPrint('Portal update failed (${portalFailureReason(error)}).');
      if (mounted) {
        if (widget.silent) {
          // No UI is visible in silent mode; report failure to the caller
          // so it can notify and offer the full sync page instead.
          _finish(false, outcome: PortalLoginOutcome.updateError);
          return;
        }
        setState(() {
          _diagnosticStageValue = 'needs_attention';
          _error =
              'Some information could not be updated. You can show the '
              'page if it needs your attention.';
          _stage = 'Update needs attention';
          _detail = 'Anything already available will remain visible.';
        });
      }
    }
  }

  Future<void> _checkSession() async {
    final authenticated = await _session.isAuthenticated();
    if (!mounted || _finished || _deadlineReached) return;
    if (authenticated) await _scrapeAndCache();
    if (!authenticated) {
      _diagnosticStageValue = 'signing_in';
      _updateStage('Signing you in', detail: 'Finishing the sign-in steps.');
    }
  }

  Future<void> _prefillPortalForm(InAppWebViewController controller) async {
    final usn = widget.initialUsn;
    final dob = widget.initialDob;
    if (usn == null || dob == null || dob.length != 10) return;
    final parts = dob.split('-');
    if (parts.length != 3) return;
    final verification = (widget.initialVerificationValue ?? '').replaceAll(
      "'",
      "\\'",
    );
    final verificationType = (widget.initialVerificationType ?? '')
        .toLowerCase()
        .replaceAll("'", "\\'");
    final script =
        """
      (function() {
        const username = document.getElementById('username');
        const isVerificationPage = document.body.innerText.toLowerCase()
          .includes('select verification type');
        if (!username && !isVerificationPage) return;
        const dd = document.getElementById('dd');
        const mm = document.getElementById('mm');
        const yyyy = document.getElementById('yyyy');
        if (username) username.value = '${usn.replaceAll("'", "\\'")}';
        // The portal's day option values contain a trailing space (for example, "08 ").
        if (dd) dd.value = '${parts[2]} ';
        if (mm) mm.value = '${parts[1]}';
        if (yyyy) yyyy.value = '${parts[0]}';
        if (typeof putdate === 'function') putdate();
        const value = '$verification';
        document.querySelectorAll('input, select').forEach(function(el) {
          const label = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '')).toLowerCase();
          if (label.includes('father') || label.includes('mother') || label.includes('parent') || label.includes('card') || label.includes('verification')) {
            el.value = value;
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          }
        });
        // Verification page: select the matching parent/ID option and fill
        // the four separate last-four-digit boxes used by the portal.
        const wanted = '$verificationType';
        document.querySelectorAll('select').forEach(function(select) {
          const option = Array.from(select.options).find(function(o) {
            const text = (o.text || '').toLowerCase();
            return wanted.includes('father') && text.includes('father') ||
              wanted.includes('mother') && text.includes('mother') ||
              wanted.includes('id') && (text.includes('id') || text.includes('card'));
          });
          if (option) {
            select.value = option.value;
            select.dispatchEvent(new Event('change', {bubbles: true}));
          }
        });
        const digits = value.split('');
        const boxes = Array.from(document.querySelectorAll('input')).filter(function(el) {
          return el.offsetParent !== null && (el.type === 'text' || el.type === 'number');
        });
        if (boxes.length >= 4 && digits.length >= 4) {
          boxes.slice(-4).forEach(function(el, index) {
            el.value = digits[index];
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          });
        }
        // Continue through ordinary portal buttons after the fields are ready.
        // The login page uses an invisible reCAPTCHA. Wait for the portal's
        // own callback to populate its hidden token before clicking Login.
        setTimeout(function() {
          const loginReady = !!(document.getElementById('username')?.value &&
            document.getElementById('dd')?.value &&
            document.getElementById('mm')?.value &&
            document.getElementById('yyyy')?.value);
          const verificationReady = boxes.length >= 4 &&
            boxes.slice(-4).every(function(el) { return el.value; });
          if (verificationReady) {
            const submit = document.querySelector('input[type="submit"], button[type="submit"]');
            if (submit) {
              submit.click();
              return;
            }
            const form = boxes[boxes.length - 1].form || document.querySelector('form');
            if (form) {
              if (typeof form.requestSubmit === 'function') form.requestSubmit();
              else form.submit();
              return;
            }
          }
          const buttons = Array.from(document.querySelectorAll('button, input[type="submit"], input[type="button"]'));
          const button = buttons.find(function(el) {
            const label = ((el.innerText || el.value || '') + '').trim().toLowerCase();
            return loginReady && label.includes('login');
          });
          const captcha = document.getElementById('captcha-response');
          if (button && !window.__officialConnectLoginScheduled) {
            window.__officialConnectLoginScheduled = true;
            let attempts = 0;
            const submitWhenReady = function() {
              attempts += 1;
              if (!captcha || captcha.value) {
                if (captcha && typeof window.check1 !== 'function') {
                  window.check1 = function() {
                    return !!captcha.value;
                  };
                }
                button.click();
                return;
              }
              if (attempts === 2 && window.grecaptcha &&
                  !window.__officialConnectRecaptchaRequested) {
                window.__officialConnectRecaptchaRequested = true;
                try {
                  window.grecaptcha.ready(function() {
                    const challenge = document.querySelector('.g-recaptcha');
                    if (!challenge) return;
                    let widgetId = 0;
                    try {
                      widgetId = window.grecaptcha.render(challenge, {
                        sitekey: challenge.dataset.sitekey,
                        size: 'invisible',
                        callback: function(token) {
                          captcha.value = token;
                          if (typeof window.onSubmit === 'function') {
                            window.onSubmit(token);
                          }
                        }
                      });
                    } catch (_) {
                      // The API may already have auto-rendered widget zero.
                    }
                    try { window.grecaptcha.execute(widgetId); } catch (_) {}
                  });
                } catch (_) {
                  window.__officialConnectRecaptchaRequested = false;
                }
              }
              if (attempts < 30) {
                setTimeout(submitWhenReady, 500);
              } else {
                window.__officialConnectLoginScheduled = false;
              }
            };
            submitWhenReady();
          }
        }, 800);
      })();
    """;
    // The portal may attach/replace its form after onLoadStop. Retry briefly
    // so autofill remains reliable on slower emulator/network runs. Once the
    // form is present, the first script run already handled it, so later
    // retries stop instead of burning their delays.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt == 1) {
        await Future.delayed(const Duration(milliseconds: 350));
      } else if (attempt == 2) {
        await Future.delayed(const Duration(milliseconds: 900));
      }
      if (!mounted || _finished || _deadlineReached || _scrapeStarted) return;
      if (attempt > 0 && await _portalFormPresent(controller)) return;
      try {
        await controller.evaluateJavascript(source: script);
      } catch (_) {
        // The route can close while a delayed autofill retry is pending.
        if (!mounted || _finished) return;
        rethrow;
      }
    }
  }

  /// Whether the login or verification form is already in the DOM. Used to
  /// skip pointless autofill retries (and their delays) on the common path.
  Future<bool> _portalFormPresent(InAppWebViewController controller) async {
    try {
      final present = await controller.evaluateJavascript(
        source: '''
          (function() {
            if (document.getElementById('username')) return true;
            if (!document.body || !document.body.innerText) return false;
            return document.body.innerText.toLowerCase()
              .includes('select verification type');
          })();
        ''',
      );
      return present == true || present?.toString() == 'true';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidePortal = widget.silent || !_showPortal;
    return Scaffold(
      backgroundColor: widget.silent
          ? Colors.transparent
          : const Color(0xfff2f7f8),
      body: Stack(
        children: [
          PortalBrowserViewport(
            hidden: hidePortal,
            child: _deadlineReached
                ? const SizedBox.shrink()
                : widget.browserBuilderForTesting?.call(
                        onLoadStop: _markInitialPageReached,
                        onNavigationStart: _startInitialConnectionDeadline,
                        onBrowserFailure: (error) {
                          unawaited(_handleBrowserFailure(error));
                        },
                        onReceivedHttpError: _handleInitialHttpError,
                        onReceivedError: (isMainFrame) {
                          if (isMainFrame &&
                              _initialNavigationStarted &&
                              !_initialPageReached) {
                            _handleInitialConnectionFailure(
                              const SocketException(
                                'Initial portal page failed',
                              ),
                            );
                          }
                        },
                      ) ??
                      widget.browserForTesting ??
                      InAppWebView(
                        initialUrlRequest: URLRequest(
                          url: WebUri('about:blank'),
                        ),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                          mediaPlaybackRequiresUserGesture: false,
                          domStorageEnabled: true,
                          databaseEnabled: true,
                          thirdPartyCookiesEnabled: true,
                        ),
                        onWebViewCreated: (controller) async {
                          if (_finished || _deadlineReached) return;
                          try {
                            _session.attachController(controller);
                            if (!widget.reuseSession) await _session.clear();
                            if (!mounted || _finished || _deadlineReached) {
                              return;
                            }
                            _startInitialConnectionDeadline();
                            await controller.loadUrl(
                              urlRequest: URLRequest(
                                url: WebUri(PortalSession.loginUri.toString()),
                              ),
                            );
                          } catch (error) {
                            await _handleBrowserFailure(error);
                          }
                        },
                        onUpdateVisitedHistory: (_, url, __) {
                          _session.rememberPage(url);
                        },
                        onLoadStop: (controller, __) async {
                          _markInitialPageReached(__?.uriValue);
                          // Scraping deliberately navigates this same hidden WebView.
                          // Treat those page loads as scraper-owned; running the login
                          // detector in parallel can redirect the browser and starve the
                          // navigation that is currently being read.
                          if (_finished || _deadlineReached || _scrapeStarted) {
                            return;
                          }
                          try {
                            _session.rememberPage(await controller.getUrl());
                            await _prefillPortalForm(controller);
                            // onLoadStop callbacks pile up across the login redirect
                            // chain and land after the scrape starts. Re-check here so
                            // stale callbacks cannot inject session probes that race
                            // the scraper's navigations on this same WebView.
                            if (_finished ||
                                _deadlineReached ||
                                _scrapeStarted) {
                              return;
                            }
                            await _checkSession();
                          } catch (error) {
                            await _handleBrowserFailure(error);
                          }
                        },
                        onReceivedError: (_, request, __) {
                          if (request.isForMainFrame == true &&
                              _initialNavigationStarted &&
                              !_initialPageReached) {
                            _handleInitialConnectionFailure(
                              const SocketException(
                                'Initial portal page failed',
                              ),
                            );
                          }
                        },
                        onReceivedHttpError: (_, request, errorResponse) {
                          _handleInitialHttpError(
                            isMainFrame: request.isForMainFrame == true,
                            statusCode: errorResponse.statusCode,
                          );
                        },
                      ),
          ),
          if (!widget.silent && !_showPortal)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xfff2f7f8),
                child: SafeArea(
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: 'Cancel',
                          onPressed: () {
                            unawaited(_recordAttention('cancelled'));
                            unawaited(_recordFinish('cancelled'));
                            _finish(
                              false,
                              outcome: PortalLoginOutcome.cancelled,
                            );
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 34),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.asset('images/logo.png', height: 82),
                              const SizedBox(height: 42),
                              if (_error == null)
                                const SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Color(0xffba3237),
                                  ),
                                )
                              else
                                const Icon(
                                  Icons.sync_problem_outlined,
                                  size: 42,
                                  color: Color(0xffba3237),
                                ),
                              const SizedBox(height: 24),
                              Text(
                                _stage,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Comfortaa',
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _detail,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Comfortaa',
                                  color: Colors.black54,
                                  height: 1.4,
                                ),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 28),
                                FilledButton.icon(
                                  onPressed: () {
                                    if (_deadlineReached) {
                                      _finish(
                                        false,
                                        outcome: PortalLoginOutcome.timeout,
                                      );
                                      return;
                                    }
                                    unawaited(
                                      _recordAttention('manual_portal'),
                                    );
                                    if (mounted && !_finished) {
                                      setState(() => _showPortal = true);
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_browser),
                                  label: Text(
                                    _deadlineReached
                                        ? 'Back to sign in'
                                        : 'Show page',
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xffba3237),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(28, 0, 28, 24),
                        child: Text(
                          'Keep the app open while your information is updated.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Comfortaa',
                            fontSize: 12,
                            color: Colors.black45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showPortal)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                elevation: 3,
                child: IconButton(
                  tooltip: 'Close portal',
                  onPressed: () => setState(() => _showPortal = false),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
