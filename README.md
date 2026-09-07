# Omathought

Hold a key, say the thing, let go. The thought is a file before you have
finished deciding whether it was worth keeping.

An Omarchy shell plugin that turns [Voxtype](https://voxtype.io/) push-to-talk
into a note library: a capture card at the bottom of the screen while you speak,
and a browser down the left-hand side for everything you have said so far. You
pick the two keys from its bar panel; it writes them for you.

![The note browser, the setup panel, and the capture card](preview.png)

## What it does

**Capture** — hold your capture key. A card appears at the bottom of the screen
and recording starts. Let go and Voxtype transcribes into the card, where the text
sits as an ordinary editable field until you decide:

- `Ctrl+Enter` saves it as a note
- `Esc` throws it away

Nothing is written until you confirm, so a misfire costs one keystroke. The
transcript is editable before saving — fixing a mangled word does not mean
re-recording the sentence.

**Browse** — press your browse key. A panel opens on the left with every note,
newest first, grouped under Today / Yesterday / Earlier this week / by month.

| Key | |
|---|---|
| `↑` `↓` | move between notes |
| `Enter` | edit the selected note |
| `Delete` | delete — press twice, the first press arms it |
| any letter | filter; every term must match |
| `Esc` | clear the filter, then close |

In the editor, `Ctrl+Enter` saves and `Esc` cancels. Editing keeps the note's
original creation time.

## Notes on disk

One Markdown file per note in `~/Documents/Thoughts`, named for the moment it
was captured:

```markdown
---
created: 2026-09-07T14:29:58+02:00
---

This is the end to end test of the capture card.
```

Plain files in a plain folder, so Obsidian, `grep`, `nvim` and a sync client all
work on them without knowing this plugin exists. Writes are atomic — a reader
never catches a half-written note.

To keep them somewhere else, point `notesDir` at another folder:

```sh
mkdir -p ~/.local/state/omarchy/settings
echo '{"notesDir": "~/Documents/Notes/voice"}' > ~/.local/state/omarchy/settings/omathought.json
```

## Requirements

- Omarchy 4 (Quattro), manifest schema 1
- A running [Voxtype](https://voxtype.io/) daemon with a working output chain —
  check with `voxtype setup check`
- `jq`, present in a normal Omarchy install

Voxtype's own `F9` cursor dictation is untouched — Omathought only adds the keys
you choose.

## Install

```sh
omarchy plugin add https://github.com/marvreichmann/omathought.git --enable
omarchy bar put com.github.marvreichmann.omathought --section right
```

A microphone icon appears in the bar, carrying a dot while no keys are set.
Click it and the panel opens:

1. Click **Hold to capture**, then press the key you want to hold while
   speaking. A bare `F10` is fine here — it sits next to Voxtype's own `F9`,
   and a bare key is far easier to hold than a chord.
2. Click **Browse notes** and press a combination for the note list. This one
   needs a modifier.

That is the whole setup. Omathought writes both bindings itself and reloads
Hyprland; you never edit a config file. Click a row again to change a key,
right-click to clear one, or **Remove key bindings** to clear both. The bar
icon keeps working either way, so unbinding can never strand you.

Pick keys that are free on your system — check with
`omarchy menu keybindings --print`. `Super+V` is *not* free: it is Omarchy's
Universal paste.

### What it writes

Bindings go into one managed block in `~/.config/hypr/bindings.lua`:

```lua
-- BEGIN com.github.marvreichmann.omathought
o.bind("F10", "Capture a thought", "omarchy-shell -q omathought captureStart")
o.bind("F10", "Capture a thought (release)", "omarchy-shell -q omathought captureStop", { release = true })
o.bind("SUPER + SHIFT + V", "Browse thoughts", "omarchy-shell -q omathought toggleBrowse")
-- END com.github.marvreichmann.omathought
```

Nothing outside that block is touched. The first write takes a one-time backup
alongside the file, writes atomically, and restores the original if `hyprctl`
reports a configuration error that was not there before.

The two `F10` lines are the push-to-talk mechanism, and both are always written
together: the second one, with `release = true`, is what makes the key
hold-to-talk instead of a toggle. Written alone, the first would record forever.

If you would rather paste them yourself, `omathought keys` prints the block and
never touches the file.

## Remove

Clear the bindings from the panel first (**Remove key bindings**), then:

```sh
omarchy plugin remove com.github.marvreichmann.omathought
```

If you remove the plugin without clearing them, delete the
`-- BEGIN com.github.marvreichmann.omathought` ... `-- END` block from
`~/.config/hypr/bindings.lua` by hand and run `hyprctl reload`. A binding left
pointing at an absent plugin does nothing, silently.

Your notes are left alone — Omathought never deletes the notes directory. To
remove them too, delete the directory `omathought dir` prints (by default
`~/Documents/Thoughts`) and the settings file at
`~/.local/state/omarchy/settings/omathought.json`.

Nothing else is touched: no packages are installed, no services registered, and
Voxtype's own configuration is never modified.

## How it works

Voxtype types its transcript into whatever holds keyboard focus. The capture
card is a layer surface that takes keyboard focus exclusively, so the transcript
lands in its text field as ordinary keystrokes — which is also why it is
editable the moment it arrives, and why nothing had to be reconfigured in
Voxtype to redirect its output.

The plugin is one `keepLoaded` overlay hosting both surfaces, plus a bar widget
whose panel owns setup. `keepLoaded` is load-bearing rather than an
optimization: the key-release binding calls into the plugin, and only a plugin
the shell has already mounted can be called.

The bar icon exists for the same reason the panel does. A plugin cannot ship a
Hyprland binding, so a fresh install has no key to press — and without an icon
it would have no surface at all, which is indistinguishable from being broken.

## Terminal use

The helper the plugin drives is usable on its own:

```sh
bin/omathought list                    # every note as JSON
bin/omathought save "a thought"        # write one, print its id
bin/omathought body <id>               # print one note
bin/omathought delete <id>
bin/omathought keys                    # print the bindings to paste
bin/omathought keys --check            # exit 0 if they are wired up
```

## License

MIT — see [LICENSE](LICENSE).
