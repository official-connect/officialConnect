#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BASELINE_COMMIT="e0715ba"
readonly MIN_RECOVERY_VERSION_CODE=8
readonly PRODUCTION_DEFINE="OFFICIAL_CONNECT_DISTRIBUTION=production"
# Single source of truth for the analytics app_version: the pubspec version
# at build time, so release_cohort segmentation never goes stale on bump.
app_version() {
  sed -n 's/^version: *//p' "$PROJECT_DIR/pubspec.yaml" | tr -d '[:space:]'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

flutter_cmd() {
  command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH"
  flutter "$@"
}

android_sdk_dir() {
  local configured
  configured="$(flutter config --list 2>/dev/null | sed -n 's/^  android-sdk: //p' | head -1)"
  if [[ -n "$configured" && -d "$configured" ]]; then
    printf '%s\n' "$configured"
  elif [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
    printf '%s\n' "$ANDROID_HOME"
  else
    die "Android SDK not found; configure Flutter or ANDROID_HOME"
  fi
}

latest_tool() {
  local pattern="$1"
  find "$(android_sdk_dir)" \( -type f -o -type l \) -path "$pattern" 2>/dev/null | sort -V | tail -1
}

check_static_config() {
  local app_gradle="$PROJECT_DIR/android/app/build.gradle"
  local settings="$PROJECT_DIR/android/settings.gradle"
  local wrapper="$PROJECT_DIR/android/gradle/wrapper/gradle-wrapper.properties"

  note "Checking Android release configuration"
  grep -Eq 'compileSdk[[:space:]]*=[[:space:]]*36' "$app_gradle" || die "compileSdk must be 36"
  grep -Eq 'targetSdk[[:space:]]*=[[:space:]]*36' "$app_gradle" || die "targetSdk must be 36"
  grep -Eq 'VERSION_17' "$app_gradle" || die "Java 17 compatibility is required"
  grep -Eq 'useLegacyPackaging[[:space:]]*=[[:space:]]*false' "$app_gradle" || die "modern JNI packaging is required"
  grep -Eq 'com.android.application" version "(8\.[5-9]|9\.)' "$settings" || die "AGP 8.5+ is required for 16 KB packaging"
  grep -Eq 'com.google.firebase.crashlytics.*3\.0\.8' "$settings" || die "Crashlytics Gradle plugin is missing"
  grep -Eq "id ['\"]com.google.firebase.crashlytics['\"]" "$app_gradle" || die "Crashlytics Gradle plugin is not applied"
  if grep -Eq 'mappingFileUploadEnabled[[:space:]]+false' "$app_gradle"; then
    grep -Eq 'minifyEnabled[[:space:]]+false' "$app_gradle" || \
      die "Crashlytics mapping upload may be disabled only for an unminified release"
    grep -Eq 'shrinkResources[[:space:]]+false' "$app_gradle" || \
      die "Resource shrinking must be disabled when release minification is disabled"
  fi
  grep -Eq 'gradle-(8\.[7-9]|9\.)' "$wrapper" || die "Gradle wrapper is older than the supported release baseline"
  [[ -f "$PROJECT_DIR/android/app/src/main/res/values-v35/styles.xml" ]] || die "API 35 edge-to-edge theme is missing"
  [[ -f "$PROJECT_DIR/android/app/src/main/res/values-night-v35/styles.xml" ]] || die "API 35 dark edge-to-edge theme is missing"
  grep -Rq 'windowOptOutEdgeToEdgeEnforcement">false' \
    "$PROJECT_DIR/android/app/src/main/res/values-v35" \
    "$PROJECT_DIR/android/app/src/main/res/values-night-v35" || die "edge-to-edge enforcement is not explicit"
  note "Static configuration passed"
}

check_native_elfs() {
  local archive="$1"
  local readelf temp_dir library found=0
  [[ -f "$archive" ]] || die "artifact not found: $archive"
  python3 "$SCRIPT_DIR/validate_android_native_libs.py" --release "$archive" || \
    die "Android artifact native-library validation failed"
  readelf="$(latest_tool '*/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf')"
  [[ -x "$readelf" ]] || die "llvm-readelf not found in the Android NDK"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/officialconnect-elf.XXXXXX")"
  trap 'rm -rf "$temp_dir"' RETURN
  unzip -qq "$archive" '*.so' -d "$temp_dir"
  while IFS= read -r -d '' library; do
    found=1
    python3 "$SCRIPT_DIR/validate_elf_load_segments.py" "$readelf" "$library" >/dev/null || \
      die "native ELF LOAD alignment validation failed: ${library#"$temp_dir/"}"
  done < <(find "$temp_dir" -type f -name '*.so' -print0)
  [[ "$found" -eq 1 ]] || die "no native libraries found in $archive"
  trap - RETURN
  rm -rf "$temp_dir"
  note "Native ELF segments are compatible with 16 KB pages"
}

check_apk_zip_alignment() {
  local apk="$1"
  local zipalign
  [[ -f "$apk" ]] || die "APK not found: $apk"
  zipalign="$(latest_tool '*/build-tools/*/zipalign')"
  [[ -x "$zipalign" ]] || die "zipalign not found in Android build-tools"
  "$zipalign" -c -P 16 -v 4 "$apk" >/dev/null || die "APK fails 16 KB zip alignment"
  note "APK zip alignment passed"
}

build_current() {
  check_static_config
  cd "$PROJECT_DIR"
  note "Building current release app bundle"
  flutter_cmd build appbundle --release --dart-define="$PRODUCTION_DEFINE" --dart-define="APP_VERSION=$(app_version)"
  check_native_elfs "$PROJECT_DIR/build/app/outputs/bundle/release/app-release.aab"
  note "Building current universal release APK"
  flutter_cmd build apk --release --dart-define="$PRODUCTION_DEFINE" --dart-define="APP_VERSION=$(app_version)"
  check_native_elfs "$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
  check_apk_zip_alignment "$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
}

build_recovery() {
  local output_path="${1:-}"
  local version_code="${2:-$MIN_RECOVERY_VERSION_CODE}"
  local temp_dir worktree artifact
  [[ -n "$output_path" ]] || die "recovery output path is required"
  [[ "$version_code" =~ ^[0-9]+$ ]] || die "recovery version code must be numeric"
  (( version_code >= MIN_RECOVERY_VERSION_CODE )) || die "recovery version code must be at least $MIN_RECOVERY_VERSION_CODE"
  git -C "$PROJECT_DIR" cat-file -e "$BASELINE_COMMIT^{commit}" || die "baseline commit $BASELINE_COMMIT is unavailable"

  [[ -d "$(dirname "$output_path")" ]] || die "recovery output directory does not exist: $(dirname "$output_path")"
  output_path="$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")"
  [[ ! -e "$output_path" ]] || die "refusing to overwrite existing recovery artifact: $output_path"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/officialconnect-recovery.XXXXXX")"
  worktree="$temp_dir/source"
  cleanup_recovery() {
    git -C "$PROJECT_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
  }
  trap cleanup_recovery EXIT INT TERM

  note "Creating detached temporary worktree at production baseline $BASELINE_COMMIT"
  git -C "$PROJECT_DIR" worktree add --detach "$worktree" "$BASELINE_COMMIT" >/dev/null

  # The production commit's Gradle 8.3/AGP configuration is no longer accepted
  # by current Flutter. Keep its application source, but use the release-tested
  # Android build harness from the caller inside this disposable worktree.
  cp "$PROJECT_DIR/android/build.gradle" "$worktree/android/build.gradle"
  cp "$PROJECT_DIR/android/settings.gradle" "$worktree/android/settings.gradle"
  cp "$PROJECT_DIR/android/gradle.properties" "$worktree/android/gradle.properties"
  cp "$PROJECT_DIR/android/gradle/wrapper/gradle-wrapper.properties" "$worktree/android/gradle/wrapper/gradle-wrapper.properties"
  cp "$PROJECT_DIR/android/app/build.gradle" "$worktree/android/app/build.gradle"
  perl -0pi -e 's/defaultConfig \{\n/defaultConfig {\n        ndk { abiFilters "arm64-v8a" }\n/' \
    "$worktree/android/app/build.gradle"
  sed -i.bak '/useLegacyPackaging = false/a\
            excludes += ["lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**"]
' "$worktree/android/app/build.gradle"
  rm "$worktree/android/app/build.gradle.bak"
  # Current Flutter can no longer compile several plugins locked by the 2025
  # release. Pin compatibility overrides to versions validated by the current
  # release; never resolve a newer major version during an emergency build.
  sed -i.bak \
    -e 's/sdk: ">=2\.16\.1 <3\.0\.0"/sdk: ">=3.8.0 <4.0.0"/' \
    -e 's/shared_preferences: \^2\.0\.13/shared_preferences: 2.5.5/' \
    -e 's/fluttertoast: \^8\.0\.9/fluttertoast: 10.0.0/' \
    -e 's/intl: \^0\.17\.0/intl: 0.20.3/' \
    -e 's/http: \^0\.13\.4/http: 1.6.0/' \
    -e 's/font_awesome_flutter: \^10\.1\.0/font_awesome_flutter: 11.0.0/' \
    -e 's/syncfusion_flutter_charts: \^20\.1\.48/syncfusion_flutter_charts: 31.2.18/' \
    -e 's/syncfusion_flutter_datepicker: \^20\.1\.50/syncfusion_flutter_datepicker: 31.2.18/' \
    -e 's/syncfusion_flutter_calendar: \^20\.1\.56/syncfusion_flutter_calendar: 31.2.18/' \
    -e 's/date_picker_plus: \^4\.1\.0/date_picker_plus: 8.0.0/' \
    "$worktree/pubspec.yaml"
  rm "$worktree/pubspec.yaml.bak" "$worktree/pubspec.lock"
  # Adapt a few baseline call sites whose dependency APIs changed with modern
  # Flutter. These compatibility edits exist only in the disposable worktree.
  perl -0pi -e 's/const FaIcon\(\s*(Icons\.[a-zA-Z_]+),/const Icon($1,/g' \
    "$worktree/lib/Screens/login_screen/student_home/unified_screen.dart"
  perl -0pi -e 's/leading: Icon\(\s*(FontAwesomeIcons\.[a-zA-Z_]+),/leading: FaIcon($1,/g' \
    "$worktree/lib/Screens/login_screen/student_home/events_screen/events_screen.dart"
  sed -i.bak 's/ChartSeries</CartesianSeries</g' \
    "$worktree/lib/Screens/login_screen/student_home/results_screen/cie_sub_screen/widgets/cie_graph.dart" \
    "$worktree/lib/Screens/login_screen/student_home/results_screen/cie_sub_screen/cie_details/cie_details_graph.dart"
  rm "$worktree/lib/Screens/login_screen/student_home/results_screen/cie_sub_screen/widgets/cie_graph.dart.bak" \
    "$worktree/lib/Screens/login_screen/student_home/results_screen/cie_sub_screen/cie_details/cie_details_graph.dart.bak"
  mkdir -p "$worktree/android/app/src/main/res/values-v35" "$worktree/android/app/src/main/res/values-night-v35"
  cp "$PROJECT_DIR/android/app/src/main/res/values-v35/styles.xml" "$worktree/android/app/src/main/res/values-v35/styles.xml"
  cp "$PROJECT_DIR/android/app/src/main/res/values-night-v35/styles.xml" "$worktree/android/app/src/main/res/values-night-v35/styles.xml"
  if [[ -f "$PROJECT_DIR/android/local.properties" ]]; then
    cp "$PROJECT_DIR/android/local.properties" "$worktree/android/local.properties"
  fi
  if [[ -f "$PROJECT_DIR/android/app/google-services.json" ]]; then
    cp "$PROJECT_DIR/android/app/google-services.json" "$worktree/android/app/google-services.json"
  fi
  if [[ -f "$PROJECT_DIR/android/key.properties" ]]; then
    cp "$PROJECT_DIR/android/key.properties" "$worktree/android/key.properties"
  fi
  if [[ -f "$PROJECT_DIR/android/upload-keystore.jks" ]]; then
    ln -s "$PROJECT_DIR/android/upload-keystore.jks" "$worktree/android/upload-keystore.jks"
  fi

  cat >"$worktree/test/recovery_smoke_test.dart" <<'DART'
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:official_connect/Classes/attendance.dart';
import 'package:official_connect/Classes/marks.dart';
import 'package:official_connect/Classes/previous_result.dart';
import 'package:official_connect/Providers/dummy_data.dart';

void main() {
  test('production baseline parses its bundled offline data contract', () {
    final data = jsonDecode(DummyData.data) as Map<String, dynamic>;
    expect(Attendance.getList(data['attendance'] as List<dynamic>), isNotEmpty);
    expect(Marks.getList(data['marks'] as List<dynamic>), isNotEmpty);
    expect(
      PreviousResult.getList(data['prevResults'] as List<dynamic>),
      isNotEmpty,
    );
  });
}
DART

  note "Running production-baseline recovery smoke test"
  (cd "$worktree" && flutter_cmd test test/recovery_smoke_test.dart)

  note "Building production source as emergency version 1.0.0+$version_code"
  # The production-era PDF plugin bundles an obsolete 32-bit pdfium binary
  # that cannot run on 16 KB devices. The recovery artifact intentionally
  # targets current 64-bit Android devices only.
  (cd "$worktree" && flutter_cmd build appbundle --release --dart-define="$PRODUCTION_DEFINE" --target-platform android-arm64 --build-name=1.0.0 --build-number="$version_code")
  artifact="$worktree/build/app/outputs/bundle/release/app-release.aab"
  check_native_elfs "$artifact"
  local staged_output="${output_path}.partial.$$"
  cp "$artifact" "$staged_output"
  mv "$staged_output" "$output_path"
  note "Recovery bundle written to $output_path"
  cleanup_recovery
  trap - EXIT INT TERM
}

usage() {
  cat <<'EOF'
Usage:
  scripts/android_release_check.sh --check
  scripts/android_release_check.sh --build-current
  scripts/android_release_check.sh --check-artifact PATH_TO_APK_OR_AAB
  scripts/android_release_check.sh --build-recovery OUTPUT_AAB [VERSION_CODE]

The recovery command builds commit e0715ba in a temporary detached worktree.
It never switches or modifies the caller's working tree. Version code defaults
to 8 and must be at least 8 so Play can accept it above production code 6 and
candidate code 7.
EOF
}

case "${1:---check}" in
  --check)
    check_static_config
    ;;
  --build-current)
    build_current
    ;;
  --check-artifact)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    check_static_config
    check_native_elfs "$2"
    if [[ "$2" == *.apk ]]; then
      check_apk_zip_alignment "$2"
    fi
    ;;
  --build-recovery)
    [[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
    build_recovery "$2" "${3:-$MIN_RECOVERY_VERSION_CODE}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
