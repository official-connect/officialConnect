import 'dart:async';

import 'package:flutter/material.dart';
import 'package:official_connect/Services/safe_external_link.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

class AppSupport {
  static const feedbackUrl = 'https://forms.gle/FyF3PZxxonNf8kUz5';
  static const sourceUrl =
      'https://github.com/official-connect/officialConnect';
  static const bugReportUrl = '$sourceUrl/issues/new?template=bug_report.yml';
  static const playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.nandan.msritconnect';

  /// Records intent separately from the external application's launch result.
  /// Neither result establishes that a form, report or review was submitted.
  static Future<bool> open(
    BuildContext context, {
    required String action,
    required String source,
    ExternalLinkLauncher? launcher,
  }) async {
    final url = switch (action) {
      'app_feedback' => feedbackUrl,
      'report_bug' => bugReportUrl,
      'source_code' => sourceUrl,
      'rate_app' => playStoreUrl,
      _ => null,
    };
    if (url == null) return false;
    unawaited(
      SyncDiagnostics.recordSupportAction(
        action: action,
        source: source,
        outcome: 'tapped',
      ),
    );
    final watch = Stopwatch()..start();
    final opened = await openExternalLink(
      context,
      Uri.parse(url),
      launcher: launcher,
    );
    watch.stop();
    unawaited(
      SyncDiagnostics.recordSupportAction(
        action: action,
        source: source,
        outcome: opened ? 'opened' : 'error',
        durationMs: watch.elapsedMilliseconds,
      ),
    );
    if (opened) {
      unawaited(SyncDiagnostics.recordFeature(action, sourceScreen: source));
    }
    return opened;
  }
}
