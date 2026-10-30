# Phone and tablet UI smoke audit

Scope: Android phones and tablets only. No Fire OS testing or support changes.
All changes remain local; nothing was uploaded or published by this audit.

## Findings and patches

- Root scaling: removed the 480-logical-pixel minimum canvas and automatic scaling. Phone icons and tap targets now retain logical dimensions; the existing 600px navigation-rail breakpoint and 900px tablet content limit remain.
- Background refresh: replaced an overlay with a natural-height footer. Page content and navigation remain accessible; multiline status text no longer relies on a fixed 56px reservation. Footer follows the selected light/dark appearance.
- Missing profile photo: corrected CircleAvatar's image-error handler so a missing image does not trigger a Flutter assertion.
- Small phone / large text: Today heading now flexes rather than overflowing its row.
- Tablet Home: capped logo width, greeting, avatar, class/course labels, announcement headings and fee headings rather than scaling them indefinitely with screen width. Receipt identifiers can wrap.
- Unpublished CIE marks: replaced a large empty chart with a compact message while preserving course cards. Zero and formatted scores still qualify for charting; nonfinite values do not.
- Removed the incorrect hardcoded version-1.0 label. A package-derived replacement remains a separate follow-up; no invented build version is displayed.

## Validation

55 targeted widget/unit checks cover adaptive navigation, responsive status, offline cached rendering, Explore/Settings, results, graph data and visual traversal. Analyzer and whitespace checks are required alongside these tests.

Visual harness: 320×640 compact phone, 412×915 A52s-like logical phone viewport, 800×1280 tablet, in light and dark mode. Traverses five main destinations, scrolls Home and expands a detail card, and renders timetable/seating empty and populated states. Refresh regressions exercise all nonidle states at 2× text scaling on compact phone and tablet. Existing tests also cover landscape tablet navigation.

Root-app tests separately verify actual logical MediaQuery sizes. This matters because earlier isolated-screen tests bypassed the root scaling wrapper.

Android API35 emulator: installed/started the debug build, viewed Home, Settings and Results on the phone viewport, changed appearance, then viewed Home and Explore at tablet size. Navigation continued to work while the Updating footer was visible. This is emulator coverage, not a physical Samsung A52s certification. No live login/scrape was revalidated in this UI audit.

## Reproduction and captures

Run:

```sh
flutter test test/adaptive_navigation_test.dart test/cie_graph_data_test.dart test/ui_responsiveness_test.dart test/explore_settings_test.dart test/widget_test.dart test/ui_visual_smoke_test.dart
flutter analyze
flutter build apk --debug
git diff --check
```

Generate local screenshots:

```sh
flutter test --update-goldens --dart-define=CAPTURE_UI=true test/ui_visual_smoke_test.dart
```

For legible default system labels in widget captures, also pass `--dart-define=SMOKE_ROBOTO=/absolute/path/to/Roboto-Regular.ttf`. The harness loads bundled Comfortaa and Material icons itself. Without Roboto, Flutter's test fallback font can show block glyphs for default labels; this is not the Android rendering.

Captures: `build/ui-smoke/` (ignored). Width/theme/screen filenames identify synthetic-data renders; `emulator-*` captures can contain private cached account data and must not be published. Captures are review artifacts, not committed golden baselines. Emoji fallback may differ between widget captures and real Android.

## Final review

CodeRabbit-style local review checked layout bounds, accessibility text, finite/zero marks, missing-image paths, persistent navigation, privacy of screenshots and test cleanup. Repairs include the avatar assertion, flexible Today heading, finite score validation and receipt wrapping. No external CodeRabbit service was run.

Limits: no physical-device certification, iOS validation, exhaustive accessibility audit, production analytics inspection, network performance measurement or fresh authentication verification. The legacy timetable fixture cannot establish the correctness of the live scraper; populated timetable/seating UI is exercised with synthetic fixtures.
