const test = require("node:test")
const assert = require("node:assert")
const Model = require("./model.js")

// A fixed "now" so grouping and time labels are not a Tuesday-only pass.
const NOW = new Date(2026, 8, 7, 14, 30, 0) // 2026-09-07 14:30 local

function note(id, body, created) {
  return { id, body, created: created === undefined ? "" : created }
}

// --------------------------------------------------------------- parseList

test("parseList reads the helper's records and orders them newest first", () => {
  const raw = JSON.stringify([
    { id: "20260901-090000", created: "2026-09-01T09:00:00+02:00", body: "older" },
    { id: "20260907-120000", created: "2026-09-07T12:00:00+02:00", body: "newer" }
  ])
  assert.deepEqual(Model.parseList(raw).map((n) => n.id),
    ["20260907-120000", "20260901-090000"])
})

test("parseList survives anything that is not a note array", () => {
  for (const raw of ["", "not json", "null", "{}", '"text"', "[1, 2]", '[{"body":"no id"}]']) {
    assert.deepEqual(Model.parseList(raw), [], `input: ${raw}`)
  }
})

test("parseList fills in missing fields rather than dropping the note", () => {
  const [n] = Model.parseList('[{"id":"20260907-120000"}]')
  assert.equal(n.created, "")
  assert.equal(n.body, "")
})

test("sortNotes orders by id, which is chronological without parsing dates", () => {
  // Deliberately unparseable `created` values: the id still has to order them.
  const notes = [note("20260101-000000", "a", "garbage"),
                 note("20261231-235959", "b", "garbage"),
                 note("20260615-120000", "c", "garbage")]
  assert.deepEqual(Model.sortNotes(notes).map((n) => n.id),
    ["20261231-235959", "20260615-120000", "20260101-000000"])
})

test("sortNotes does not mutate its input", () => {
  const notes = [note("20260101-000000", "a"), note("20261231-235959", "b")]
  Model.sortNotes(notes)
  assert.equal(notes[0].id, "20260101-000000")
})

// ------------------------------------------------------------------ titles

test("noteTitle takes the first non-empty line", () => {
  assert.equal(Model.noteTitle("\n\n  Call the dentist  \nand the vet"), "Call the dentist")
})

test("noteTitle drops the trailing punctuation dictation always adds", () => {
  assert.equal(Model.noteTitle("Buy oat milk."), "Buy oat milk")
  assert.equal(Model.noteTitle("Did I lock the door?"), "Did I lock the door")
  assert.equal(Model.noteTitle("Wait!!!"), "Wait")
})

test("noteTitle falls back rather than returning an empty label", () => {
  assert.equal(Model.noteTitle(""), "Untitled")
  assert.equal(Model.noteTitle("   \n  \n"), "Untitled")
  assert.equal(Model.noteTitle("..."), "Untitled")
  assert.equal(Model.noteTitle(null), "Untitled")
})

test("notePreview is everything after the title, on one line", () => {
  assert.equal(Model.notePreview("Title\n\nfirst\nsecond"), "first second")
})

test("notePreview is empty for a single-line note", () => {
  assert.equal(Model.notePreview("Just the one line"), "")
})

// ---------------------------------------------------------------- truncate

test("truncate leaves short text alone", () => {
  assert.equal(Model.truncate("short", 20), "short")
})

test("truncate breaks on a word boundary when one is near the limit", () => {
  assert.equal(Model.truncate("alpha beta gamma delta", 17), "alpha beta gamma…")
})

test("truncate cuts mid-word rather than losing most of the text", () => {
  // The only space is early, so honouring it would return almost nothing.
  assert.equal(Model.truncate("a bbbbbbbbbbbbbbbbbbbbbbbb", 10), "a bbbbbbbb…")
})

test("truncate handles a zero limit and empty input", () => {
  assert.equal(Model.truncate("anything", 0), "")
  assert.equal(Model.truncate("", 10), "")
})

test("wordCount ignores surrounding and repeated whitespace", () => {
  assert.equal(Model.wordCount("  one   two\nthree  "), 3)
  assert.equal(Model.wordCount("   "), 0)
  assert.equal(Model.wordCount(""), 0)
})

// ---------------------------------------------------------------- calendar

test("noteDate prefers the frontmatter stamp", () => {
  const d = Model.noteDate(note("20260101-000000", "", "2026-09-07T12:00:00+02:00"))
  assert.equal(d.getFullYear(), 2026)
  assert.equal(d.getMonth(), 8)
})

test("noteDate falls back to the id when the stamp is missing or broken", () => {
  for (const created of ["", "not a date"]) {
    const d = Model.noteDate(note("20260907-143052", "", created))
    assert.equal(d.getFullYear(), 2026)
    assert.equal(d.getMonth(), 8)
    assert.equal(d.getDate(), 7)
    assert.equal(d.getHours(), 14)
    assert.equal(d.getMinutes(), 30)
  }
})

test("noteDate gives up on an id it did not mint", () => {
  assert.equal(Model.noteDate(note("nonsense", "")), null)
  assert.equal(Model.noteDate(null), null)
})

test("groupLabel names the recent buckets", () => {
  assert.equal(Model.groupLabel(new Date(2026, 8, 7, 9, 0), NOW), "Today")
  assert.equal(Model.groupLabel(new Date(2026, 8, 6, 9, 0), NOW), "Yesterday")
  assert.equal(Model.groupLabel(new Date(2026, 8, 3, 9, 0), NOW), "Earlier this week")
  assert.equal(Model.groupLabel(new Date(2026, 7, 3, 9, 0), NOW), "August 2026")
  assert.equal(Model.groupLabel(new Date(2025, 7, 3, 9, 0), NOW), "August 2025")
})

test("groupLabel labels an undated note instead of crashing", () => {
  assert.equal(Model.groupLabel(null, NOW), "Undated")
})

test("timeLabel shows a clock for the last week and adds a date beyond it", () => {
  assert.equal(Model.timeLabel(new Date(2026, 8, 7, 9, 5), NOW), "09:05")
  assert.equal(Model.timeLabel(new Date(2026, 8, 3, 18, 40), NOW), "18:40")
  assert.equal(Model.timeLabel(new Date(2026, 7, 3, 8, 0), NOW), "3 Aug 08:00")
})

// ------------------------------------------------------------------- rows

test("buildRows interleaves one heading per group", () => {
  const notes = [
    note("20260907-120000", "today one", "2026-09-07T12:00:00"),
    note("20260907-090000", "today two", "2026-09-07T09:00:00"),
    note("20260906-090000", "yesterday", "2026-09-06T09:00:00")
  ]
  const kinds = Model.buildRows(notes, NOW).map((r) => r.kind + ":" + (r.label || r.id))
  assert.deepEqual(kinds, [
    "heading:Today",
    "note:20260907-120000",
    "note:20260907-090000",
    "heading:Yesterday",
    "note:20260906-090000"
  ])
})

test("buildRows is empty for no notes, so the view shows its empty state", () => {
  assert.deepEqual(Model.buildRows([], NOW), [])
})

test("buildRows carries the display fields each row renders", () => {
  const rows = Model.buildRows([note("20260907-120000", "Title here.\nand the body", "2026-09-07T12:00:00")], NOW)
  const row = rows[1]
  assert.equal(row.title, "Title here")
  assert.equal(row.preview, "and the body")
  assert.equal(row.time, "12:00")
  // Counted over the whole body, title line included.
  assert.equal(row.words, 5)
})

// ----------------------------------------------------------------- search

test("filterNotes requires every term, in any order or position", () => {
  const notes = [note("1", "buy oat milk"), note("2", "call the dentist"), note("3", "milk the cow")]
  assert.deepEqual(Model.filterNotes(notes, "milk").map((n) => n.id), ["1", "3"])
  assert.deepEqual(Model.filterNotes(notes, "milk oat").map((n) => n.id), ["1"])
  assert.deepEqual(Model.filterNotes(notes, "nothing").map((n) => n.id), [])
})

test("filterNotes matches substrings, so a term need not be a whole word", () => {
  // Deliberate: typing "dent" should find "dentist" while the memo is still
  // being narrowed down. The cost is that "oat" also matches "goat".
  const notes = [note("1", "call the dentist"), note("2", "milk the goat")]
  assert.deepEqual(Model.filterNotes(notes, "dent").map((n) => n.id), ["1"])
  assert.deepEqual(Model.filterNotes(notes, "oat").map((n) => n.id), ["2"])
})

test("filterNotes ignores case and is a no-op for a blank query", () => {
  const notes = [note("1", "Buy OAT milk")]
  assert.equal(Model.filterNotes(notes, "oat").length, 1)
  assert.equal(Model.filterNotes(notes, "   ").length, 1)
  assert.equal(Model.filterNotes(notes, "").length, 1)
})

// -------------------------------------------------------------- selection

test("moveSelection steps over headings so the cursor never lands on one", () => {
  const rows = Model.buildRows([
    note("20260907-120000", "a", "2026-09-07T12:00:00"),
    note("20260906-120000", "b", "2026-09-06T12:00:00")
  ], NOW)
  // Rows are: heading, a, heading, b.
  assert.equal(Model.moveSelection(rows, "20260907-120000", 1), "20260906-120000")
  assert.equal(Model.moveSelection(rows, "20260906-120000", -1), "20260907-120000")
})

test("moveSelection clamps at both ends instead of wrapping", () => {
  const rows = Model.buildRows([
    note("20260907-120000", "a", "2026-09-07T12:00:00"),
    note("20260907-110000", "b", "2026-09-07T11:00:00")
  ], NOW)
  assert.equal(Model.moveSelection(rows, "20260907-120000", -1), "20260907-120000")
  assert.equal(Model.moveSelection(rows, "20260907-110000", 1), "20260907-110000")
})

test("moveSelection recovers when the cursor is on a note that is gone", () => {
  const rows = Model.buildRows([note("20260907-120000", "a", "2026-09-07T12:00:00")], NOW)
  assert.equal(Model.moveSelection(rows, "deleted-id", 1), "20260907-120000")
  assert.equal(Model.moveSelection([], "anything", 1), "")
})

test("selectionAfterDelete lands on the row that took the deleted one's place", () => {
  const notes = [note("a", "1"), note("b", "2"), note("c", "3")]
  assert.equal(Model.selectionAfterDelete(notes, "b"), "c")
})

test("selectionAfterDelete steps back when the last note is removed", () => {
  const notes = [note("a", "1"), note("b", "2"), note("c", "3")]
  assert.equal(Model.selectionAfterDelete(notes, "c"), "b")
})

test("selectionAfterDelete clears the cursor when nothing is left", () => {
  assert.equal(Model.selectionAfterDelete([note("a", "1")], "a"), "")
})

test("findNote returns null rather than undefined for a miss", () => {
  assert.equal(Model.findNote([note("a", "1")], "b"), null)
  assert.equal(Model.findNote([], "a"), null)
})

// ----------------------------------------------------------- transcripts

test("cleanTranscript collapses the whitespace dictation leaves behind", () => {
  assert.equal(Model.cleanTranscript("  hello   there  "), "hello there")
  assert.equal(Model.cleanTranscript("line one  \n   line two"), "line one\nline two")
  assert.equal(Model.cleanTranscript("a\r\nb"), "a\nb")
})

test("cleanTranscript keeps one blank line as a paragraph break", () => {
  assert.equal(Model.cleanTranscript("one\n\ntwo"), "one\n\ntwo")
  assert.equal(Model.cleanTranscript("one\n\n\n\ntwo"), "one\n\ntwo")
})

test("isSaveable rejects a memo that is only whitespace", () => {
  assert.equal(Model.isSaveable("real words"), true)
  assert.equal(Model.isSaveable("   \n\t\n "), false)
  assert.equal(Model.isSaveable(""), false)
  assert.equal(Model.isSaveable(null), false)
})

test("captureStatus describes each phase of a capture", () => {
  assert.match(Model.captureStatus("recording", false), /Listening/)
  assert.match(Model.captureStatus("transcribing", false), /Transcribing/)
  assert.match(Model.captureStatus("saving", true), /Saving/)
  assert.match(Model.captureStatus("error", false), /not responding/)
  assert.match(Model.captureStatus("ready", true), /Ctrl\+Enter/)
  assert.match(Model.captureStatus("ready", false), /Nothing captured/)
})
