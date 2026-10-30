# Crashlytics check — 29 October 2026

Read directly from Firebase's Android Crashlytics dashboard for 23–29 October.
These are distinct categories; nonfatal sync events are not app crashes.

## Fatal startup crash

- Five events affecting one user; the issue detail's version chart assigns all
  five to 1.1.5 (14). The issue list's broader version range is not evidence of
  five crashes in the latest release.
- Huawei Enjoy 9s, Android 11. Firebase flags the reported device as rooted.
- `ApkLibraryInstaller.installLibrary` throws `MissingLibraryException` because
  `libflutter.so` cannot be found for the requested ARM ABIs.
- The failure occurs during Flutter engine initialization, before Dart login or
  scraping code can execute.
- This proves a native-library loading failure. It does not establish whether
  installation damage, split APK handling, device modification, or a packaging
  defect caused it. Inspecting local artifacts cannot prove what was installed
  on that person's device.

[Firebase issue](https://console.firebase.google.com/project/unofficialconnect/crashlytics/app/android:com.nandan.msritconnect/issues/a8879835192b57ce682e7a76f3c16a88?time=7d&types=crash)

## App-not-responding reports

Four ANR events affected four users:

- `FlutterImageView.acquireLatestImage`: two events / two users.
- `MessageQueue.nativePollOnce`: one event / one user; Firebase labels its root
  cause unknown.
- `FlutterJNI.nativeDispatchPlatformMessage`: one event / one user, version
  1.1.7 (16), Nokia 6.2, Android 11, app in background. The stack passes through
  `InAppWebViewChromeClient.onReceivedIcon`, `WebViewChannelDelegate.onReceivedIcon`
  and a platform-channel send.

The last stack justifies investigating unnecessary WebView icon callbacks and
browser lifetime during background refresh. It does not prove that disabling a
callback eliminates all ANRs, nor identify the cause of the other three events.

[Current-release ANR](https://console.firebase.google.com/project/unofficialconnect/crashlytics/app/android:com.nandan.msritconnect/issues/829a94b56779de59570cfa2732c63658?time=7d&types=ANR)

## Interpretation

The unfiltered crash view reported 99.98% crash-free users and sessions for the
selected seven days. Large nonfatal counts still indicate a reliability problem,
but they must be analyzed separately from fatal crashes and ANRs. The local
integration audit documents what was reproduced and tested; production outcomes
require observation after a reviewed release.
