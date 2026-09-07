# Changelog

All notable changes to this project are documented here, in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form. This project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-07

### Added

- Push-to-talk capture. Hold the capture key and a card appears at the bottom of
  the screen with recording already running; release it and the transcript lands
  in the card as editable text. `Ctrl+Enter` saves, `Esc` discards — nothing
  reaches disk until you confirm.
- A note browser down the left of the screen: every note newest-first, grouped
  under Today, Yesterday, Earlier this week, and by month. Arrow keys move,
  `Enter` edits, `Delete` pressed twice deletes, and typing filters on every
  term at once.
- Notes as one Markdown file each in `~/Documents/Thoughts`, with a `created`
  stamp in frontmatter and the transcript as the body. Written atomically, so
  another reader never sees a half-finished note. Editing a note keeps its
  original creation time.
- `notesDir` in `~/.local/state/omarchy/settings/omathought.json`, for keeping
  notes somewhere else.
- `bin/omathought`, the helper the plugin drives, usable on its own from a
  terminal for `list`, `save`, `body`, `update` and `delete`.

[Unreleased]: https://github.com/marvreichmann/omathought/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/marvreichmann/omathought/releases/tag/v0.1.0
