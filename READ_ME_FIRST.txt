GoFlow cloud-build kit
======================
These are the only files the cloud robot needs.

When you upload to GitHub, upload ALL of these together (one upload):
  - pubspec.yaml
  - the  lib  folder  (contains main.dart)
  - the  .github  folder  (contains the build recipe)

You can ignore this text file - it does not need to be uploaded.

NOTE: the app is in DEMO MODE right now, so the button works with no
hardware. When your PCB is ready, open lib/main.dart, change
  const bool kDemoMode = true;
to
  const bool kDemoMode = false;
and build again to talk to the real device.
