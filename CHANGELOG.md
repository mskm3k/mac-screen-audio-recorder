# Changelog

## v1.0.2 / Build 16 — 2026-10-10

- Fixed overlapping screen-recording permission dialogs. The macOS system dialog is now given priority; the app uses its existing status label to provide guidance.
- Retained recording, system audio, window/region capture, app icon, UI layout and Bundle ID.
- Public-source build procedure tested on Mac: compilation, app launch, screen recording, system audio recording, and permission reset/system permission prompt.

## v1.0.1 / Build 15

- Recorded the selected window rectangle via display capture so visible pop-ups and pull-down menus within that rectangle can be captured.
- Retained the prior UI, app icon, capture modes and audio features.
