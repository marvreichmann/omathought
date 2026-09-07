# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Omarchy shell plugin (QML / Quickshell) that captures Voxtype push-to-talk
dictation into a library of Markdown notes. There is no build step — the plugin
is `Overlay.qml`, `Model.js` and `bin/omathought` plus `manifest.json`.
`README.md` documents the user-facing behaviour and `CHANGELOG.md` the release
history.

Develop in this repository, never in the installed copy.

For any question about the rules an Omarchy plugin has to follow — manifest
schema, entry points and kinds, what the shell loads and when, the plugin APIs —
consult <https://plugins.omarchy.org/develop.html> rather than guessing. The
notes below record what this plugin actually depends on; that page is the
authority.

## Tests

`Model.js` is covered by unit tests, run with Node's built-in runner — no
dependencies, nothing to install:

```sh
node --test tests/*.test.js
```

`tests/model.js` evaluates `Model.js` (minus its `.pragma library` line) in the
host realm and returns its top-level declarations, so a new pure function is
testable without an export list — and without the cross-realm prototypes that
make every `deepEqual` fail while printing two identical-looking values.

Anything decidable without a running shell belongs in `Model.js`: grouping,
titles, truncation, filtering, cursor movement after a delete. Nothing below it
— processes, layer surfaces, focus — has automated coverage, so changes there go
through the loop that follows.

The helper script is exercised directly, which is most of its point:

```sh
XDG_STATE_HOME=/tmp/oth-state bin/omathought save "hello"   # with notesDir pointed at /tmp
XDG_STATE_HOME=/tmp/oth-state bin/omathought list | jq
```

## Test loop

Testing the QML requires copying everything to the installed location, whose
folder name must match `manifest.json`'s `id`:

```sh
cp -a manifest.json Overlay.qml Model.js README.md LICENSE bin \
  ~/.config/omarchy/plugins/com.github.marvreichmann.omathought/
```

The shell watches local plugins and reloads on change, but a failed load is not
retried until a full rescan, so after fixing a QML syntax error:

```sh
omarchy-shell shell rescanPlugins
journalctl --user --since -30s | grep -i omathought
```

Lint before loading. `qmllint` is not on `PATH`; it needs the shell tree mounted
under the name `qs`, or every `qs.Ui` import fails and the real warnings are
buried:

```sh
mkdir -p /tmp/qsimports && ln -sfn /usr/share/omarchy/shell /tmp/qsimports/qs
/usr/lib/qt6/bin/qmllint -I /tmp/qsimports Overlay.qml
```

Expect residual warnings — `PanelWindow is not creatable`, `QProcess::ExitStatus`
on `onExited`, and `missing-property` on every `Style.*`/`Color.*` token, because
qmllint cannot see into the singletons' nested `QtObject` groups. A first-party
overlay (`plugins/emojis/Emojis.qml`) produces the same classes; compare against
it rather than chasing them to zero.

Drive the plugin over IPC, which is also exactly what the keybindings do:

```sh
omarchy-shell omathought captureStart    # also: captureStop, captureCancel, browse, toggleBrowse
```

**`wtype` reaches the surfaces but not the keybindings.** Hyprland ignores
virtual-keyboard input when matching binds, so `wtype -P F10` does nothing while
`wtype -k Down` drives the browser fine. Keyboard paths inside a surface are
testable; the bind itself is only verifiable as a registration
(`hyprctl -j binds`) plus running its command string by hand.

Screenshots: `grim -o DP-1` for one monitor. On a three-monitor setup a
full-width `grim` is 11520px across and the capture card is a 720px box in the
middle of one screen — crop to the monitor first or you will conclude the card
never rendered.

## Architecture

Three files, and the split is about what can be tested:

- **`bin/omathought`** — every read and write of a note. Bash, argv-only, no
  stdin: the QML passes transcripts as a single argv element so dictated text is
  never parsed as shell. Owns the notes directory, the file format, atomic
  writes, and the id validation.
- **`Model.js`** — a `.pragma library` of pure functions: parsing the helper's
  JSON, titles and previews, date grouping and time labels, the flat
  heading-plus-note row model, filtering, and cursor movement. No IO.
- **`Overlay.qml`** — both layer surfaces, the Voxtype lifecycle, and the IPC
  handler. Rendering and process spawning only; decisions belong in `Model.js`.

### Invariants that break things when violated

- **The capture card must hold keyboard focus exclusively.** Voxtype types its
  transcript into whatever has the keyboard — that is the entire mechanism by
  which text reaches the card. Drop `WlrKeyboardFocus.Exclusive` and the
  transcript goes to whatever was focused before, which is the user's editor.
- **`keepLoaded: true` is load-bearing, not an optimization.** The key-release
  binding calls `captureStop` over IPC; a plugin the shell has not mounted has
  no IPC target, so recording would never stop.
- Key repeat fires `captureStart` again while the key is held. `startCapture`
  returns early during `recording`/`transcribing` — without that guard the
  repeat restarts the recording and eats the first half of the sentence.
- Voxtype signals nothing when it has finished typing. The end of a transcript
  is inferred from the text going quiet (`settleTimer`), with
  `transcribeTimeout` as the backstop so a dead daemon cannot strand the card in
  "Transcribing…". Both timers must be stopped on dismiss.
- Dismissing mid-recording has to `voxtype record cancel`. Closing the card
  without it leaves the daemon listening, and the next transcript arrives with
  no card to land in — i.e. typed into whatever the user is doing.
- `shell.hide()` is called only once *both* surfaces are down (`releaseIfIdle`).
  The host tracks one open flag per plugin id, so releasing it while the other
  surface is still up desyncs the host from what is on screen.
- The browser's row model interleaves headings with notes, so a ListView index
  is not a stable handle on a note. The cursor is `selectedId`, and
  `Model.moveSelection` steps over headings; `currentIndex` is deliberately
  unused.
- `strip_frontmatter` drops the blank line after the header. It is part of the
  format, not the note — without dropping it, every edit reads it back, renders
  it under a fresh separator, and the note grows a blank line per save.
- Note ids reaching the helper are validated against the exact minted shape
  before being pasted into a path. They arrive from the overlay; traversal is
  refused, not sanitized.
- An edit that empties a note is refused rather than saved. Silently turning a
  save into a delete is the one destructive thing the editor could do.

## Shell APIs this plugin relies on

- An **overlay** entry point is a plain `Item` the shell loads and injects
  `shell`, `manifest`, `omarchyPath` (and `service`, if the plugin declares one)
  into. It is expected to define `open(payloadJson)`, `close()` and `toggle()`.
  `omarchy-shell shell summon <id> '<json>'` routes its payload to `open`.
- **`manifest.__sourceDir`** is the plugin's own directory on disk, stamped in by
  `PluginRegistry`. It is the only way to find bundled files like `bin/`.
- A plugin gets **one entry point per kind**, so two surfaces means one overlay
  hosting two `PanelWindow`s — not two overlay entries.
- A non-bar plugin is *enabled* by appearing in the top-level `plugins[]` array
  of `shell.json`, which is what `omarchy plugin enable <id>` writes. It must be
  known to the registry first: after a fresh copy into the plugins directory,
  `omarchy-shell shell rescanPlugins` before enabling, or the enable is refused
  as an unknown plugin.
- `IpcHandler { target: "omathought" }` registers `omarchy-shell omathought
  <method>`. The target name is independent of the plugin id, and short is
  better — it goes in every keybinding.
- Tokens come from `qs.Commons` (`Style`, `Color`, `Border`, `Util`) and
  components from `qs.Ui` (`BorderSurface`). Read `/usr/share/omarchy/shell/Ui/`
  before inventing a control. `plugins/emojis/Emojis.qml` and
  `plugins/reminders/ReminderFlow.qml` are the reference overlays.

## Voxtype contract

Verified against the installed daemon — do not trust secondhand descriptions:

- `voxtype record start|stop|cancel|toggle` drives the daemon by signal. `start`
  and `stop` are the push-to-talk pair; `cancel` discards without transcribing.
- Output mode is **global config**, not per-invocation
  (`output.mode` in `~/.config/voxtype/config.toml`). There is no flag to make
  one recording go somewhere else, which is why this plugin catches the
  transcript through keyboard focus instead of reconfiguring anything.
- The typing backend is whichever of `wtype` / `ydotool` / `eitype` is installed
  — `wtype` here, `ydotool` is *not* required. `voxtype setup check` prints the
  resolved chain.
- `voxtype status` prints `idle` / `recording` / `transcribing`, and
  `--format json --follow` streams changes. Requires `state_file` in the config,
  which defaults to `auto`.

## Before publishing

Reference: <https://plugins.omarchy.org/publish.html>.

`omarchy plugin validate <folder>` mirrors the checks the shell enforces —
schemaVersion, required fields, safe relative entry points that exist, an entry
point per declared kind, no symlinks, no reserved id. It exits 0 silently. It
does **not** check what the marketplace listing needs:

- `author`, `description` and `license` in `manifest.json`, with `license`
  matching what `LICENSE` says.
- `README.md`, `LICENSE` and `preview.png` at the repository root.
- `homepage` pointing at the public repository.

`preview.png` is still missing — capture the browser panel and the capture card
together before the first release.

## Releasing

Each version is a GitHub release whose notes are the matching `CHANGELOG.md`
section — the file is the source, the release is a copy. To cut one:

1. Add changes under `## [Unreleased]` as you go, in Keep a Changelog form,
   written for someone using the plugin rather than reading the diff.
2. Rename that heading to `## [x.y.z] - YYYY-MM-DD`, add a fresh empty
   `## [Unreleased]`, and update the link definitions at the bottom.
3. Bump `version` in `manifest.json` to match. The workflow refuses a tag that
   disagrees.
4. Commit, then `git tag vx.y.z && git push origin main --follow-tags`.
