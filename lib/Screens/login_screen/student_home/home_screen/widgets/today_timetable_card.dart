import 'dart:async';

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:official_connect/Classes/timetable_entry.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Providers/themes.dart';
import 'package:official_connect/Screens/login_screen/student_home/timetable_screen/timetable_screen.dart';
import 'package:official_connect/Services/sync_diagnostics.dart';

class TodayTimetableCard extends StatelessWidget {
  const TodayTimetableCard({super.key, required this.sisData});

  final SisData sisData;

  @override
  Widget build(BuildContext context) {
    final entries = sisData.timetableFor(DateTime.now());
    final now = DateTime.now();
    final upcoming = entries.where((entry) {
      final end = _minutes(entry.time, end: true);
      return end == null || end >= now.hour * 60 + now.minute;
    }).toList();
    final visible = upcoming.take(2).toList();
    final syncStatus = sisData.syncStatusFor('timetable');
    final textStyle = CustomTheme.textStyle(context);
    final subtitle = CustomTheme.buttonSubtitle(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Neumorphic(
        style: CustomTheme.neumorphicStyle(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    color: Color(0xffba3237),
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Today',
                      style: textStyle.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      if (entries.isNotEmpty &&
                          syncStatus != 'error' &&
                          syncStatus != 'disabled' &&
                          syncStatus != 'unknown') ...[
                        const Icon(
                          Icons.celebration_outlined,
                          color: Color(0xff55b98a),
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          syncStatus == 'error'
                              ? 'Timetable unavailable'
                              : syncStatus == 'disabled'
                              ? 'Timetable temporarily unavailable'
                              : syncStatus == 'unknown'
                              ? 'Update to load your timetable'
                              : entries.isEmpty
                              ? 'No classes today'
                              : 'Classes are done for today 🎉',
                          style:
                              entries.isNotEmpty &&
                                  syncStatus != 'error' &&
                                  syncStatus != 'disabled' &&
                                  syncStatus != 'unknown'
                              ? subtitle.copyWith(
                                  color: const Color(0xff55b98a),
                                  fontWeight: FontWeight.w700,
                                )
                              : subtitle,
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...visible.indexed.map(
                  (value) => _ClassRow(
                    entry: value.$2,
                    label: value.$1 == 0 ? null : 'Next',
                    subtitle: subtitle,
                    title: textStyle,
                  ),
                ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    unawaited(SyncDiagnostics.recordFeature('timetable'));
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const TimetableScreen(),
                      ),
                    );
                  },
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('Full timetable'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xffba3237),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

int? _minutes(String value, {required bool end}) {
  final matches = RegExp(r'(\d{1,2}):(\d{2})').allMatches(value).toList();
  if (matches.isEmpty) return null;
  final match = end && matches.length > 1 ? matches.last : matches.first;
  final hour = int.tryParse(match.group(1)!);
  final minute = int.tryParse(match.group(2)!);
  return hour == null || minute == null ? null : hour * 60 + minute;
}

class _ClassRow extends StatelessWidget {
  const _ClassRow({
    required this.entry,
    required this.label,
    required this.subtitle,
    required this.title,
  });

  final TimetableEntry entry;
  final String? label;
  final TextStyle subtitle;
  final TextStyle title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffba3237).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          left: BorderSide(color: Color(0xffba3237), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Text(label!, style: subtitle.copyWith(fontWeight: FontWeight.w700)),
          Text(entry.time, style: subtitle),
          const SizedBox(height: 3),
          Text(
            entry.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: title.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (entry.room.isNotEmpty || entry.batch.isNotEmpty)
            Text(
              [
                entry.room,
                entry.batch,
              ].where((value) => value.isNotEmpty).join(' · '),
              style: subtitle,
            ),
        ],
      ),
    ),
  );
}
