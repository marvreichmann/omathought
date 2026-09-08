# Changelog

All notable changes to this project are documented here, in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form. This project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-08

First release.

### Added

- Push-to-talk capture. Hold the capture key and a card appears at the bottom of
  the focused screen with recording already running; release it and the
  transcript lands in the card as editable text. `Ctrl+Enter` saves,
  `Esc` discards — nothing reaches disk until you confirm.
- A note browser down the left of the screen: every note newest-first, grouped
  under Today, Yesterday, Earlier this week, and by month. Arrow keys move,
  `Enter` edits, `Delete` pressed twice deletes, and typing filters on every
  term at once.
- A bar icon whose panel sets both keybindings. Click a row, press a
  combination, and Omathought writes it into a managed block in
  `bindings.lua` and reloads Hyprland — no config file to edit by hand. Click
  again to change a key, right-click to clear one, or **Remove key bindings**
  to clear both. The icon carries a dot until the keys are set.
- Notes as one Markdown file each in `~/Documents/Thoughts`, with a `created`
  stamp in frontmatter and the transcript as the body. Written atomically, so
  another reader never sees a half-finished note. Editing a note keeps its
  original creation time.
- `notesDir` in `~/.local/state/omarchy/settings/omathought.json`, for keeping
  notes somewhere else.
- `bin/omathought`, the helper the plugin drives, usable on its own from a
  terminal for `list`, `save`, `body`, `update`, `delete` and `keys`.

### Notes

Both surfaces open on the monitor Hyprland has focused, rather than on whichever
screen Quickshell enumerates first — on a multi-monitor setup the latter makes a
keypress look like it did nothing while the card is up on another screen.

Writes to `bindings.lua` take a one-time backup, replace only the plugin's own
block, and restore the original if `hyprctl` reports a configuration error that
was not there before. Nothing else on the system is modified: no packages, no
services, and none of Voxtype's own configuration.

[Unreleased]: https://github.com/marvreichmann/omathought/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/marvreichmann/omathought/releases/tag/v1.0.0
