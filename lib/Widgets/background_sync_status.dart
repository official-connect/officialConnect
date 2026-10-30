import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:official_connect/Screens/login_screen/portal_refresh.dart';

class BackgroundSyncStatus extends StatelessWidget {
  const BackgroundSyncStatus({super.key, this.listenable});

  final ValueListenable<BackgroundSyncState>? listenable;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BackgroundSyncState>(
      valueListenable: listenable ?? backgroundSyncState,
      builder: (context, state, _) {
        final visible = state != BackgroundSyncState.idle;
        final colors = Theme.of(context).colorScheme;
        final (IconData icon, String label, Color color) = switch (state) {
          BackgroundSyncState.updating => (
            Icons.sync_rounded,
            'Updating',
            colors.primary,
          ),
          BackgroundSyncState.success => (
            Icons.check_circle_outline,
            'Updated',
            const Color(0xff287a45),
          ),
          BackgroundSyncState.partial => (
            Icons.info_outline_rounded,
            'Some information could not be updated',
            const Color(0xff9a6400),
          ),
          BackgroundSyncState.error => (
            Icons.sync_problem_outlined,
            'Update needs attention',
            colors.error,
          ),
          BackgroundSyncState.idle => (
            Icons.sync_rounded,
            '',
            Colors.transparent,
          ),
        };

        return IgnorePointer(
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            offset: visible ? Offset.zero : const Offset(0, 0.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: visible ? 1 : 0,
              child: Semantics(
                liveRegion: true,
                label: label,
                child: Material(
                  key: const ValueKey('background-sync-status'),
                  color: Colors.transparent,
                  elevation: 0,
                  borderRadius: BorderRadius.circular(999),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 330),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state == BackgroundSyncState.updating)
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: color,
                              ),
                            )
                          else
                            Icon(icon, size: 18, color: color),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurface,
                                fontFamily: 'Comfortaa',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
