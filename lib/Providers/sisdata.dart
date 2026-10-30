// ignore_for_file: dead_code

import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:official_connect/Classes/attendance.dart';
import 'package:official_connect/Classes/fees_data.dart';
import 'package:official_connect/Classes/marks.dart';
import 'package:official_connect/Classes/previous_result.dart';
import 'package:official_connect/Classes/sis_proctor_data.dart';
import 'package:official_connect/Classes/timetable_entry.dart';
import 'package:official_connect/Classes/seating_arrangement.dart';
import 'package:official_connect/Providers/dummy_data.dart';
import 'dart:convert' as convert;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:official_connect/Services/firebase_feature_flags.dart';
import 'package:official_connect/Services/firebase_operations.dart';

class SisData with ChangeNotifier {
  static const currentCacheSchemaVersion = 2;
  static const _cacheSchemaVersionKey = 'cacheSchemaVersion';

  Map<String, dynamic> _data = {};
  List<Attendance> _attendances = [];
  List<FeesData> _fees = [];
  List<Marks> _marks = [];
  List<PreviousResult> _previousResults = [];
  List<TimetableEntry> _timetable = [];
  List<SeatingArrangement> _seating = [];
  bool _hasData = false;
  bool isValidData = true;
  bool needToUpdate = false;
  String _usn = "";
  String _dob = "";
  int _creditsEarned = 0;
  int _toEarn = 0;
  String _section = "";
  String _course = "";
  String _semester = "";
  String _name = "";
  String _batch = "";
  String _categoryAlloted = "";
  String _categoryClaimed = "";
  String _courseFullName = "";
  String _email = "";
  String _phone = "";
  String _studentImage = "";
  String _errorMessage = "";
  String _themeMode = 'system';
  bool _darkMode = false;
  bool _diagnosticsEnabled = true;
  double _ver = 0.0;
  String _downloadLink = "";
  SisProctorData _proctorData = SisProctorData([], "", "", "", "");
  SisData() {
    // Re-evaluate the effective theme when the OS theme changes while the
    // preference is set to "system".
    ui.PlatformDispatcher.instance.onPlatformBrightnessChanged = () {
      if (_themeMode == 'system') notifyListeners();
    };
    // cleanData();
    setup();
  }

  Future<bool> isConnected() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return true;
      }
    } on SocketException catch (_) {
      return false;
    }
    return false;
  }

  static void showToast(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 1,
      backgroundColor: const Color(0xffba3237),
      textColor: Colors.white,
      fontSize: 16.0,
    );
  }

  void setup() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // if we already have data, check if the data is
    if (prefs.containsKey('hasData') && prefs.getBool('hasData') == true) {
      _hasData = true;
      var time = prefs.getInt('timeStamp') ?? 0;
      final savedUsn = (prefs.getString('usn') ?? '').trim().toUpperCase();
      _usn = savedUsn;
      _dob = prefs.getString('dob') ?? "";
      _darkMode = prefs.getBool('darkMode') ?? false;
      // Migrate the old boolean preference: an explicit dark/light choice is
      // kept, otherwise the theme follows the OS setting.
      _themeMode =
          prefs.getString('themeMode') ??
          (prefs.containsKey('darkMode')
              ? (_darkMode ? 'dark' : 'light')
              : 'system');
      _diagnosticsEnabled = prefs.getBool('diagnosticsEnabled') ?? true;
      // Apply consent immediately, but native telemetry acknowledgements must
      // never hold up restoring the academic cache or opening the home screen.
      unawaited(
        FirebaseOperations.setDiagnosticsEnabled(
          _diagnosticsEnabled,
        ).catchError(
          (Object _) =>
              debugPrint('App health preference could not be applied.'),
        ),
      );
      debugPrint(
        "data was there before. checking if it is older than 12 hours",
      );
      final timestampNeedsRefresh =
          DateTime.fromMillisecondsSinceEpoch(
            time,
          ).difference(DateTime.now()).inMilliseconds.abs() >
          const Duration(hours: 12).inMilliseconds;

      // A missing or corrupted cache payload must never leave the app stuck
      // on the loading spinner: mark it as logged out instead.
      final raw = prefs.getString('data');
      if (raw == null || raw.isEmpty) {
        debugPrint('cache flagged as present but payload missing; resetting');
        await prefs.setBool('hasData', false);
        _hasData = false;
        notifyListeners();
        return;
      }
      try {
        _data = Map<String, dynamic>.from(await convert.jsonDecode(raw) as Map);
        // Older cache payloads stored the account only in SharedPreferences.
        // Restore that known identity before setVariables derives _usn from
        // the payload. If the key exists but is invalid, keep identity unknown.
        if (!_data.containsKey('usn') && savedUsn.isNotEmpty) {
          _data['usn'] = savedUsn;
        } else if (_data['usn'] is String &&
            (_data['usn'] as String).trim().isNotEmpty) {
          _data['usn'] = (_data['usn'] as String).trim().toUpperCase();
        }
      } catch (_) {
        debugPrint('cached payload unreadable; resetting');
        await prefs.setBool('hasData', false);
        _hasData = false;
        _data = {};
        notifyListeners();
        return;
      }
      // Keep showing cached data immediately. Refresh uses the authenticated
      // portal WebView session. A cache created by an older app can still be
      // perfectly usable, but it needs one refresh to populate newly added
      // sections such as timetable and seating.
      await setVariables();
      final storedSchemaVersion = prefs.getInt(_cacheSchemaVersionKey) ?? 0;
      final missingCurrentSections =
          !_data.containsKey('timetable') || !_data.containsKey('seating');
      final staleCurrentSections =
          const ['attendance', 'marks', 'timetable', 'seating'].any((section) {
            final status = syncStatusFor(section);
            return status == 'error' ||
                status == 'partial' ||
                status == 'pending' ||
                (status == 'disabled' &&
                    FirebaseFeatureFlags.sectionEnabled(section));
          });
      needToUpdate =
          timestampNeedsRefresh ||
          storedSchemaVersion < currentCacheSchemaVersion ||
          missingCurrentSections ||
          staleCurrentSections;

      notifyListeners();
    }
  }

  /// Loads the bundled demo account. Real accounts are populated exclusively
  /// by [applyPortalData] after the authenticated on-device WebView scrape.
  Future<void> loadDummyData() async {
    _hasData = false;
    notifyListeners();
    debugPrint("getting dummy data");
    _data = await convert.jsonDecode(DummyData.data);
    if (_data.isEmpty) {
      isValidData = false;
      _errorMessage =
          _errorMessage ==
              "We encountered a Server error. Sorry for the inconvinience"
          ? "We encountered a Server error. Sorry for the inconvinience"
          : "Error! please check the entered details";
    } else {
      isValidData = true;
    }
    _hasData = true;
    needToUpdate = false;
    if (_data.isNotEmpty) {
      setVariables();
    }
    notifyListeners();
  }

  /// Applies data scraped inside the authenticated portal WebView and writes
  /// it to the same cache used by the existing native screens.
  Future<void> applyPortalData(
    Map<String, dynamic> data,
    String usn,
    String dob, {
    void Function(String step)? onStage,
  }) async {
    onStage?.call('parse');
    final normalizedUsn = usn.trim().toUpperCase();
    final cachedUsn = _usn.trim().toUpperCase();
    final sameAccount = cachedUsn.isNotEmpty && cachedUsn == normalizedUsn;
    final previous = sameAccount
        ? Map<String, dynamic>.from(_data)
        : <String, dynamic>{};
    final merged = Map<String, dynamic>.from(data);
    final sync = Map<String, dynamic>.from(
      (merged['_sync'] as Map?) ?? const {},
    );
    final sections = Map<String, dynamic>.from(
      (sync['sections'] as Map?) ?? const {},
    );
    const sectionKeys = {
      'attendance': ['attendance'],
      'marks': ['marks'],
      'results': ['prevResults'],
      'fees': ['fees', 'refunds'],
      'proctor': ['proctorship'],
      'timetable': ['timetable'],
      'seating': ['seating'],
    };
    final invalidSections = <String>{};
    for (final entry in sectionKeys.entries) {
      final status = (sections[entry.key] as Map?)?['status'];
      // Error/disabled sections may deliberately use legacy empty-list
      // placeholders even where the healthy model expects a map.
      if (status == 'error' || status == 'disabled') continue;
      for (final key in entry.value) {
        if (!merged.containsKey(key)) continue;
        try {
          _validatePortalSection(key, merged[key]);
        } catch (_) {
          invalidSections.add(entry.key);
          for (final sectionKey in entry.value) {
            if (previous.containsKey(sectionKey)) {
              merged[sectionKey] = previous[sectionKey];
            } else {
              merged.remove(sectionKey);
            }
          }
          break;
        }
      }
    }
    for (final entry in sectionKeys.entries) {
      final sectionStatus = Map<String, dynamic>.from(
        (sections[entry.key] as Map?) ?? const {},
      );
      final status = sectionStatus['status'];
      if (invalidSections.contains(entry.key)) {
        sectionStatus['status'] = 'error';
        sectionStatus['failure_reason'] = 'parse_error';
        sections[entry.key] = sectionStatus;
        continue;
      }
      if (status == 'error' || status == 'disabled') {
        for (final key in entry.value) {
          if (previous.containsKey(key)) merged[key] = previous[key];
        }
      } else if (status == 'partial' &&
          (entry.key == 'attendance' || entry.key == 'marks')) {
        final key = entry.value.single;
        merged[key] = _mergePartialCourseData(
          previous[key],
          merged[key],
          section: entry.key,
        );
      }
    }
    if (invalidSections.isNotEmpty) {
      sync['sections'] = sections;
      sync['outcome'] = 'partial';
      merged['_sync'] = sync;
    }
    // A partial profile update should not blank fields already shown by the
    // app. Successful empty data sections are still allowed to replace cache.
    for (final entry in previous.entries) {
      if (!merged.containsKey(entry.key) && entry.key != '_sync') {
        merged[entry.key] = entry.value;
      }
    }
    merged['usn'] = normalizedUsn;
    _data = merged;
    _usn = normalizedUsn;
    _dob = dob;
    _hasData = true;
    isValidData = true;
    final unresolvedRefresh =
        const ['attendance', 'marks', 'timetable', 'seating'].any((section) {
          final status = (sections[section] as Map?)?['status'];
          return status == 'error' ||
              status == 'partial' ||
              status == 'pending';
        });
    needToUpdate = unresolvedRefresh;
    await setVariables();
    if (!isValidData || _data.isEmpty) {
      throw const FormatException('Portal data is incompatible with the app');
    }
    final prefs = await SharedPreferences.getInstance();
    onStage?.call('persist');
    await prefs.setString('data', convert.jsonEncode(merged));
    await prefs.setString('usn', _usn);
    await prefs.setString('dob', _dob);
    await prefs.setBool('hasData', true);
    await prefs.setInt('timeStamp', DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_cacheSchemaVersionKey, currentCacheSchemaVersion);
    notifyListeners();
  }

  void _validatePortalSection(String key, Object? value) {
    switch (key) {
      case 'attendance':
        if (value is! List) throw const FormatException();
        Attendance.getList(value);
      case 'marks':
        if (value is! List) throw const FormatException();
        Marks.getList(value);
      case 'fees':
        if (value is! List) throw const FormatException();
        FeesData.getList(value);
      case 'refunds':
        if (value is! List || value.any((item) => item is! Map)) {
          throw const FormatException();
        }
      case 'prevResults':
        if (value is! List) throw const FormatException();
        for (final result in value) {
          if (result is! Map || result['results'] is! List) {
            throw const FormatException();
          }
        }
        if (PreviousResult.getList(value).length != value.length) {
          throw const FormatException();
        }
      case 'proctorship':
        if (value is List && value.isEmpty) return;
        if (value is! Map) throw const FormatException();
        SisProctorData.proctorData(value);
      case 'timetable':
      case 'seating':
        if (value is! List || value.any((item) => item is! Map)) {
          throw const FormatException();
        }
    }
  }

  List<dynamic> _mergePartialCourseData(
    Object? cached,
    Object? refreshed, {
    required String section,
  }) {
    final mergedByIdentity = <String, dynamic>{};
    final unidentified = <dynamic>[];

    void addItems(Object? source) {
      if (source is! List) return;
      for (final item in source) {
        if (item is! Map) continue;
        final identity = _courseIdentity(item, section: section);
        if (identity.isEmpty) {
          unidentified.add(item);
        } else {
          // Cached values are inserted first; refreshed values with the same
          // stable identity replace them when this helper is called second.
          mergedByIdentity[identity] = item;
        }
      }
    }

    addItems(cached);
    addItems(refreshed);
    return [...mergedByIdentity.values, ...unidentified];
  }

  String _courseIdentity(Map item, {required String section}) {
    String normalize(Object? value) =>
        value.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    if (section == 'attendance') {
      final code = normalize(item['code']);
      if (code.isNotEmpty) return 'code:$code';
    }

    final name = item['name']?.toString() ?? '';
    final codeInName = RegExp(
      r'\(([a-z0-9]+)\)',
      caseSensitive: false,
    ).firstMatch(name)?.group(1);
    if (codeInName != null && codeInName.isNotEmpty) {
      return 'code:${normalize(codeInName)}';
    }
    final normalizedName = normalize(name);
    return normalizedName.isEmpty ? '' : 'name:$normalizedName';
  }

  // after getting any sort of data, the data has to be read from. this does that
  Future<void> setVariables() async {
    debugPrint("setting variables");

    try {
      const debug = true;

      _usn = _data['usn'] ?? '';
      _proctorData = SisProctorData.proctorData(_data['proctorship'] ?? []);
      if (debug) debugPrint("Proctor data");

      _previousResults = PreviousResult.getList(_data['prevResults'] ?? []);
      if (debug) debugPrint("Previous Results");

      _timetable = TimetableEntry.getList(_data['timetable'] ?? []);
      _seating = SeatingArrangement.getList(_data['seating'] ?? []);

      _attendances = Attendance.getList(_data['attendance'] ?? []);
      if (debug) debugPrint("Attendances");

      _fees = FeesData.getList(_data['fees'] ?? []);
      if (debug) debugPrint("Fees");

      _marks = Marks.getList(_data['marks'] ?? []);
      if (debug) debugPrint("Marks");

      _creditsEarned = int.tryParse(_data['earned'] ?? '0') ?? 0;
      if (debug) debugPrint("Earned");

      _toEarn = int.tryParse(_data['to_earn'] ?? '0') ?? 0;
      if (debug) debugPrint("To earn");

      _name = _data['name'] ?? 'Unknown';
      if (debug) debugPrint("name");

      _section = _data["sec"] ?? 'Unknown';
      if (debug) debugPrint("sec");

      _course = _data["courseSmall"] ?? 'Unknown';
      if (debug) debugPrint("courseSmall");

      _semester = _data["sem"] ?? 'Unknown';
      if (debug) debugPrint("sem");

      _batch = _data["BATCH:"] ?? 'Unknown';
      if (debug) debugPrint("batch");

      _categoryAlloted = _data["Category Alloted:"] ?? 'Unknown';
      if (debug) debugPrint("category alotted");

      _categoryClaimed = _data["Category Claimed:"] ?? 'Unknown';
      if (debug) debugPrint("category claimed ");

      _courseFullName = _data["Course:"] ?? 'Unknown';
      if (debug) debugPrint("Course");

      _email = _data["Email Id:"] ?? 'Unknown';
      if (debug) debugPrint("Email Id");

      _phone = _data["MOBILE:"] ?? 'Unknown';
      if (debug) debugPrint("Mobile");

      _studentImage = _data["studentImage"] ?? '';
      if (debug) debugPrint("Student Image");

      _ver = double.tryParse(_data["ver"] ?? '1.0') ?? 1.0;
      if (debug) debugPrint("version");

      _downloadLink = _data["downloadLink"] ?? '';
      if (debug) debugPrint("downloadLink");
    } catch (_) {
      debugPrint('student data could not be parsed');
      _hasData = true;
      isValidData = false;

      _errorMessage =
          "Error in processing data! Contact Your IT department to resolve this issue";
      _data = {};
      notifyListeners();
    }
  }

  void cleanData() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Keep portal_* autofill suggestions across sign-out. A user can erase the
    // whole saved login set by clearing the USN on the native login screen.
    for (final key in const [
      'hasData',
      'timeStamp',
      _cacheSchemaVersionKey,
      'usn',
      'dob',
      'proctorEmail',
      'darkMode',
      'data',
      'auth',
    ]) {
      await prefs.remove(key);
    }
    _usn = "";
    _data = {};
    isValidData = true;
    _hasData = false;
    _usn = "";
    _darkMode = false;
    _dob = "";
    notifyListeners();
  }

  Map<String, dynamic> get data {
    return _data;
  }

  String get usn {
    return _usn;
  }

  Future<void> setDark(bool val) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    prefs.setBool('darkMode', val);
  }

  set darkMode(bool val) {
    _darkMode = val;
    themeMode = val ? 'dark' : 'light';
  }

  /// 'system' (default), 'light' or 'dark'.
  String get themeMode => _themeMode;

  set themeMode(String val) {
    _themeMode = val;
    _darkMode = val == 'dark';
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('themeMode', val);
    });
    notifyListeners();
  }

  bool get darkMode {
    if (_themeMode == 'dark') return true;
    if (_themeMode == 'light') return false;
    return ui.PlatformDispatcher.instance.platformBrightness ==
        ui.Brightness.dark;
  }

  bool get diagnosticsEnabled => _diagnosticsEnabled;

  set diagnosticsEnabled(bool value) {
    _diagnosticsEnabled = value;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('diagnosticsEnabled', value);
    });
    FirebaseOperations.setDiagnosticsEnabled(value);
    notifyListeners();
  }

  bool get hasData {
    return _hasData;
  }

  List<FeesData> get fees {
    return _fees;
  }

  List<Marks> get marks {
    return _marks;
  }

  List<PreviousResult> get previousResults {
    return _previousResults;
  }

  List<TimetableEntry> get timetable => List.unmodifiable(_timetable);

  List<SeatingArrangement> get seating => List.unmodifiable(_seating);

  List<TimetableEntry> timetableFor(DateTime date) {
    final key =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _timetable.where((entry) => entry.date == key).toList();
  }

  List<Attendance> get attendances {
    return _attendances;
  }

  int get creditsEarned {
    return _creditsEarned;
  }

  int get toEarn {
    return _toEarn;
  }

  String get section {
    return _section;
  }

  String get course {
    return _course;
  }

  String get semester {
    return _semester;
  }

  String get batch {
    return _batch;
  }

  String get categoryAlloted {
    return _categoryAlloted;
  }

  String get errorMessage {
    return _errorMessage;
  }

  String get categoryClaimed {
    return _categoryClaimed;
  }

  String get courseFullName {
    return _courseFullName;
  }

  String get email {
    return _email;
  }

  String get phone {
    return _phone;
  }

  String get studentName {
    return _name;
  }

  SisProctorData get proctordata {
    return _proctorData;
  }

  bool get updating {
    return needToUpdate;
  }

  double get ver {
    return _ver;
  }

  String get downloadLink {
    return _downloadLink;
  }

  String get studentImage {
    return _studentImage;
  }

  Map<String, dynamic> get syncMetadata =>
      Map<String, dynamic>.from((_data['_sync'] as Map?) ?? const {});

  String syncStatusFor(String section) {
    final sections = syncMetadata['sections'] as Map?;
    return (sections?[section] as Map?)?['status']?.toString() ?? 'unknown';
  }

  bool get hasSyncIssues {
    final sections = syncMetadata['sections'] as Map?;
    if (sections == null) return false;
    return sections.values.whereType<Map>().any((section) {
      final status = section['status'];
      return status == 'partial' || status == 'error';
    });
  }

  bool get isSyncPending =>
      ((syncMetadata['sections'] as Map?)?.values ?? const [])
          .whereType<Map>()
          .any((section) => section['status'] == 'pending');
}
