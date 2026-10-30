# Android native-library artifact audit — 2026-10-29

## Finding

The reported Crashlytics signal (provided for this investigation) is five
actual crashes affecting one user, all reported on version `1.1.5 (14)`, with
`MissingLibraryException` for `libflutter.so` and no libraries found across
the loader's reported ABI search paths. The Huawei Enjoy 9s / Android 11 and
rooted-device flag are also from the supplied report; they were not
independently verified here.

The local release artifacts inspected below contain `libflutter.so` in their
base/APK payloads for every ABI they package. The current workspace release AAB
and APK also pass the existing 16 KB ELF alignment check, and the APK passes
ZIP alignment. These files are local artifacts dated October 3, 2026; their
contents do not establish which artifact or split set reached the affected
device, and do not explain the crash.

## Artifacts inspected

| Artifact | SHA-256 | Packaged ABIs | Result |
| --- | --- | --- | --- |
| `build/app/outputs/bundle/release/app-release.aab` | `29fdbcca0a49474a646d6331138de226a6929dc3f9818e891e1120bf65fe00f2` | arm64-v8a, armeabi-v7a, x86_64 | `libflutter.so` present per ABI; 16 KB ELF alignment passed |
| `build/app/outputs/flutter-apk/app-release.apk` | `611a5a6273549531b215bfefcfb76c144f65de89da8a03075e86186b4d614484` | arm64-v8a, armeabi-v7a, x86_64 | `libflutter.so` present per ABI; 16 KB ELF and APK ZIP alignment passed |
| `outputs/OfficialConnect-android.apk` | `2b7203e276231a7db00a91ca5a5757af61cf63949d948a721974fcf3660a9b64` | arm64-v8a, armeabi-v7a, x86_64 | `libflutter.so` present per ABI; structural check only |
| `outputs/recovery/officialconnect-recovery-1.0.0+8.aab` | `a121661e5a62660d912bf0d9556063c5b8542e7d8a1709402626da88bb13b3f5` | arm64-v8a | `libflutter.so` present; structural check only |
| `outputs/recovery/officialconnect-recovery-1.0.0+9.aab` | `dc49cdaf5c6834c9ee3a2e8d7ba19ace5c8247bdac9180a87b695a9fe713581e` | arm64-v8a | `libflutter.so` present; structural check only |

The fresh serial release APK build completed on October 29 at 19:59 IST.
`build/app/outputs/flutter-apk/app-release.apk` is 74,603,599 bytes with
SHA-256 `cb066e7efe4e9b669125e24c4c3ab963b83e4ea237af441c9692d24566482aad`.
The final release-mode artifact check after the synthetic tests found both
`libflutter.so` and `libapp.so` for arm64-v8a, armeabi-v7a, and x86_64; all
native LOAD segments passed 16 KB alignment and APK ZIP alignment passed.

## Validation added

`android_release_check.sh --check-artifact` now verifies release-library
presence before ELF checks: `libflutter.so` and `libapp.so` are required for
each packaged ABI. The generic structural validator can inspect debug APKs
without requiring `libapp.so`; the release check explicitly selects release
mode. AAB validation uses the `base` module, so an optional feature module
cannot mask a missing Flutter startup library. The ELF check now fails on
nonzero `llvm-readelf` exits, malformed output, absent LOAD segments, and
sub-16-KB LOAD alignment. Synthetic ZIP and fake-readelf tests cover these
cases:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The validation intentionally makes no manifest or ABI-filter changes. To
identify the device-specific cause, compare the delivered version's artifact
and generated split APK set with the affected installation.
