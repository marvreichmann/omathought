.pragma library

// Pure functions behind Omathought. Nothing here touches the filesystem, spawns
// a process, or reads QML state: the helper script owns IO and hands this file
// records, so every decision about what a note *is* stays checkable by
// `node --test tests/`.

// ------------------------------------------------------------------ records

// The helper emits one record per note: { id, created, body }. `id` is the
// basename without ".md" and doubles as the sort key, because the filename is
// minted from the creation timestamp and never rewritten by an edit.
function parseList(raw) {
  var parsed
  try {
    parsed = JSON.parse(raw || "[]")
  } catch (e) {
    return []
  }
  if (!Array.isArray(parsed)) return []

  var out = []
  for (var i = 0; i < parsed.length; i++) {
    var n = normalizeNote(parsed[i])
    if (n) out.push(n)
  }
  return sortNotes(out)
}

function normalizeNote(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = typeof raw.id === "string" ? raw.id : ""
  if (!id) return null
  return {
    id: id,
    created: typeof raw.created === "string" ? raw.created : "",
    body: typeof raw.body === "string" ? raw.body : ""
  }
}

// Newest first. Ids are `YYYYMMDD-HHMMSS`, so a plain string compare is already
// chronological — no Date parsing, and it still orders notes whose frontmatter
// was mangled by an external editor.
function sortNotes(notes) {
  var copy = notes.slice()
  copy.sort(function (a, b) {
    if (a.id === b.id) return 0
    return a.id < b.id ? 1 : -1
  })
  return copy
}

// ------------------------------------------------------------------ display

// A voice memo has no title of its own, so the first non-empty line becomes
// one. Trailing sentence punctuation is dropped: dictation ends nearly every
// utterance with a period, and a column of titles all ending in "." reads as
// noise.
function noteTitle(body) {
  var lines = String(body || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    return line.replace(/[.,;:!?\s]+$/, "") || "Untitled"
  }
  return "Untitled"
}

// Everything after the title line, flattened to one line for the list row.
function notePreview(body) {
  var lines = String(body || "").split("\n")
  var seenTitle = false
  var rest = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (!seenTitle) { seenTitle = true; continue }
    rest.push(line)
  }
  return rest.join(" ")
}

function truncate(text, limit) {
  var s = String(text || "")
  if (limit <= 0) return ""
  if (s.length <= limit) return s
  // Break on a word boundary when one is close enough to the limit that the
  // result is not visibly shorter than the hard cut would have been.
  var cut = s.slice(0, limit)
  var space = cut.lastIndexOf(" ")
  if (space > limit * 0.6) cut = cut.slice(0, space)
  return cut.replace(/[\s.,;:]+$/, "") + "…"
}

function wordCount(body) {
  var trimmed = String(body || "").trim()
  if (!trimmed) return 0
  return trimmed.split(/\s+/).length
}

// ----------------------------------------------------------------- calendar

// `created` is ISO 8601 with an offset, written by the helper via `date -Is`.
// A note whose frontmatter went missing falls back to the id, which carries the
// same instant in local time.
function noteDate(note) {
  if (!note) return null
  if (note.created) {
    var parsed = new Date(note.created)
    if (!isNaN(parsed.getTime())) return parsed
  }
  return dateFromId(note.id)
}

function dateFromId(id) {
  var m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/.exec(String(id || ""))
  if (!m) return null
  var d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])
  return isNaN(d.getTime()) ? null : d
}

function sameDay(a, b) {
  return !!a && !!b
    && a.getFullYear() === b.getFullYear()
    && a.getMonth() === b.getMonth()
    && a.getDate() === b.getDate()
}

// The heading a note sits under in the browser. Days are grouped rather than
// dated because a memo library is read by recency, not by calendar.
function groupLabel(date, now) {
  if (!date) return "Undated"
  var today = now || new Date()
  if (sameDay(date, today)) return "Today"

  var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
  if (sameDay(date, yesterday)) return "Yesterday"

  var weekAgo = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 6)
  if (date >= weekAgo && date <= today) return "Earlier this week"

  if (date.getFullYear() === today.getFullYear()) return monthName(date) + " " + date.getFullYear()
  return monthName(date) + " " + date.getFullYear()
}

function monthName(date) {
  var names = ["January", "February", "March", "April", "May", "June",
               "July", "August", "September", "October", "November", "December"]
  return names[date.getMonth()]
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// Clock time for a row: the day is already carried by the group heading, so
// only same-year-but-older notes need a date at all.
function timeLabel(date, now) {
  if (!date) return ""
  var today = now || new Date()
  var clock = pad2(date.getHours()) + ":" + pad2(date.getMinutes())
  if (sameDay(date, today)) return clock

  var weekAgo = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 6)
  if (date >= weekAgo && date <= today) return clock
  return date.getDate() + " " + monthName(date).slice(0, 3) + " " + clock
}

// Build the flat row model the browser's ListView renders: group headings
// interleaved with notes, so one view scrolls both without a section delegate.
function buildRows(notes, now) {
  var rows = []
  var current = null
  for (var i = 0; i < notes.length; i++) {
    var note = notes[i]
    var date = noteDate(note)
    var label = groupLabel(date, now)
    if (label !== current) {
      rows.push({ kind: "heading", id: "heading:" + label, label: label })
      current = label
    }
    rows.push({
      kind: "note",
      id: note.id,
      title: truncate(noteTitle(note.body), 64),
      preview: truncate(notePreview(note.body), 96),
      time: timeLabel(date, now),
      words: wordCount(note.body)
    })
  }
  return rows
}

// ------------------------------------------------------------------- search

function matchesQuery(note, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return true
  var terms = q.split(/\s+/)
  var hay = String(note.body || "").toLowerCase()
  for (var i = 0; i < terms.length; i++) {
    if (hay.indexOf(terms[i]) === -1) return false
  }
  return true
}

function filterNotes(notes, query) {
  var out = []
  for (var i = 0; i < notes.length; i++) {
    if (matchesQuery(notes[i], query)) out.push(notes[i])
  }
  return out
}

// ---------------------------------------------------------------- selection

// Move the cursor by `delta` over note rows only, skipping headings so arrow
// keys never land on one. Clamped rather than wrapping: wrapping from the last
// note back to the top reads as a failed keypress in a list this short.
function moveSelection(rows, currentId, delta) {
  var noteIds = []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind === "note") noteIds.push(rows[i].id)
  }
  if (noteIds.length === 0) return ""

  var at = noteIds.indexOf(currentId)
  if (at === -1) return noteIds[0]

  var next = at + delta
  if (next < 0) next = 0
  if (next > noteIds.length - 1) next = noteIds.length - 1
  return noteIds[next]
}

// After a delete, land on the note that took the deleted one's place — the next
// one down, or the new last note when the tail was removed.
function selectionAfterDelete(notes, deletedId) {
  var at = -1
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].id === deletedId) { at = i; break }
  }
  if (at === -1) return notes.length > 0 ? notes[0].id : ""

  var remaining = notes.slice(0, at).concat(notes.slice(at + 1))
  if (remaining.length === 0) return ""
  return remaining[Math.min(at, remaining.length - 1)].id
}

function findNote(notes, id) {
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].id === id) return notes[i]
  }
  return null
}

// ------------------------------------------------------------------ capture

// Voxtype types its transcript into whatever holds keyboard focus, so the
// capture card receives it as ordinary keystrokes and this only has to tidy the
// result: collapse the stray whitespace dictation leaves behind, and never save
// a memo that is only whitespace.
function cleanTranscript(text) {
  return String(text || "")
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
}

function isSaveable(text) {
  return cleanTranscript(text).length > 0
}

// What the capture card says about itself. Kept here so the wording is covered
// by tests rather than scattered through bindings.
function captureStatus(phase, hasText) {
  if (phase === "recording") return "Listening… release to transcribe"
  if (phase === "transcribing") return "Transcribing…"
  if (phase === "saving") return "Saving…"
  if (phase === "error") return "Voxtype is not responding"
  if (hasText) return "Ctrl+Enter to save · Esc to discard"
  return "Nothing captured · Esc to close"
}
