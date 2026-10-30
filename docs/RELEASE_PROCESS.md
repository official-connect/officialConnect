# Release Process (maintainers)

Releasing has two separate stages. Creating a GitHub Release does **not**
publish to Google Play — Play submission is a second, manually supervised
step.

## 1. Release PR

Open a PR against `main` that bumps `version:` in `pubspec.yaml`
(e.g. `1.2.3+4`). CI must be green: the `verify` job
(`flutter analyze lib test`, `flutter test`, debug APK build) and the
`history` job (TruffleHog scan of the full history). Both are required on
`main`. Merge the PR; do not tag until it lands.

## 2. Tag the release

Tag exactly the pubspec version and push the tag:

```sh
git tag v1.2.3+4 && git push origin v1.2.3+4
```

Only repository administrators create or retarget release tags. The active
GitHub tag ruleset `Maintainer release tags` (26176892) restricts creation,
update, and deletion of `refs/tags/v*`; only the repository administrator
role can bypass it. Workflow SHA validation detects stale runs and validates
the intended commit; it does not itself make tags immutable. The `Release`
workflow also refuses a tag that does not match `pubspec.yaml`.

## 3. CI builds and publishes the GitHub Release

On the tag push, `release.yml` restores signing and Firebase config from
repository secrets (see `docs/RELEASE_SECRETS.md`), re-runs analyze and
tests, builds the signed release AAB and APK with the production
telemetry markers (`OFFICIAL_CONNECT_DISTRIBUTION=production` and the
pubspec `APP_VERSION`, same as
`scripts/android_release_check.sh --build-current`), verifies both with
`scripts/android_release_check.sh --check-artifact`, and publishes a
GitHub Release with both artifacts plus SHA-256 checksums.

To validate without publishing: Actions → Release → Run workflow
(dry run — artifacts land on the workflow run only). A manual run with
`publish` set also creates the Release; it is maintainer-only.

The release artifact check verifies that every native ABI packaged in the APK
or AAB base module contains both `libflutter.so` and `libapp.so`. The generic
structural validator requires `libflutter.so`; the release check enables its
release mode, which also requires `libapp.so`. For an AAB it ignores optional
feature modules when checking Flutter startup libraries; a library present
only in a feature module cannot satisfy the base app. The ELF check fails if
`llvm-readelf` exits unsuccessfully, reports malformed output, reports no LOAD
segments, or finds any LOAD alignment below 16 KB. APKs also receive the ZIP
alignment check. Test these validators with synthetic artifacts without
building or signing an app:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

These checks prove what is present in the inspected artifact. They do not
identify the cause of a device-specific `MissingLibraryException`; compare the
artifact actually delivered to that device and its installed split APK set.

At this point the release exists on GitHub only. No user receives it
until step 4.

## 4. Supervised Play submission and verification

Upload the verified AAB from the GitHub Release to Play as a deliberate,
supervised step — via Play Console, or via the guarded API wrapper in
`docs/PLAY_API_RELEASES.md` (explicit track/rollout, `PLAY_PUBLISH_CONFIRM=YES`).
Prefer internal testing first; stage production with an explicit fraction.

After submission, verify in Play Console: the release, its rollout
state, the pre-launch report, and vitals. Keep the prior production
artifact available for recovery.

## Rollback

Play has no downgrade path: a published version cannot be overwritten
with older artifacts. If a rollout goes wrong:

1. Halt the rollout in Play Console immediately.
2. Remediate with a **new, higher version** (higher version code than
   anything already uploaded) — see the safeguards in
   `docs/PLAY_API_RELEASES.md`. The recovery-bundle procedure in
   `distribution/ANDROID_RELEASE.md` is currently stale (its baseline
   commit is absent from this history); the owner must designate a fresh
   verified baseline before relying on it.
3. Release the fix through this same process (release PR → tag → GitHub
   Release → supervised Play submission).
