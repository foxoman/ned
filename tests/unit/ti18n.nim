## The interface in other languages (src/ned/core/i18n.nim): a catalogue's texts found whole, those with parts that
## change ($1 …) in any order, $$ a dollar sign, the spaces around a text kept, a part that is a word of the
## catalogue translated too, the pseudo language, the language of the system's settings, a file of yours over ned's,
## and what is said when a catalogue cannot be read.
## Run: nim r tests/unit/ti18n.nim

import std/[os, strutils, unittest]
import ../../src/ned/core/i18n

const De = """{
 "@language": "Deutsch",
 "Save": "Speichern",
 "File": "Datei",
 "on": "an",
 "Saved $1 files": "$1 Dateien gespeichert",
 "Move $1 to $2": "$2: $1 verschieben",
 "Wrap: $1": "Umbruch: $1",
 "Costs $$5": "Kostet 5 $$",
 "Price: $$$1": "Preis: $1 $$",
 "Imports updated in $1 file(s)$2": "Importe in $1 Datei(en) erneuert$2",
 "$1: $2": "nie",
 "Untranslated": ""
}"""

suite "i18n":
  test "English: every text as it is":
    check trLoad("en", [("de", De)]).len == 0
    check not trOn
    check tr("Save") == "Save"
    check trf("Saved $1 files", 3) == "Saved 3 files"
    check trLanguage() == ""

  test "a catalogue: whole texts, its name, how many":
    check trLoad("de", [("de", De)]).len == 0
    check trOn
    check trLanguage() == "de"
    check trLanguageName() == "Deutsch"
    check tr("Save") == "Speichern"
    check tr("Nothing like it") == "Nothing like it"
    check tr("Untranslated") == "Untranslated"              # (an empty translation: the English stays)
    check trCount() >= 8

  test "the spaces around a text stay":
    discard trLoad("de", [("de", De)])
    check tr(" File ") == " Datei "
    check tr("  Save") == "  Speichern"
    check tr("   ") == "   "

  test "texts with parts: found whole, the parts in the translation's order":
    discard trLoad("de", [("de", De)])
    check tr("Saved 12 files") == "12 Dateien gespeichert"
    check tr("Move a.nim to src/b.nim") == "src/b.nim: a.nim verschieben"
    check trf("Move $1 to $2", "x", "y") == "y: x verschieben"
    check trf("Saved $1 files", 7) == "7 Dateien gespeichert"
    check trf("Not in it: $1", "z") == "Not in it: z"

  test "a part that is a word of the catalogue is translated too":
    discard trLoad("de", [("de", De)])
    check tr("Wrap: on") == "Umbruch: an"
    check tr("Wrap: off") == "Umbruch: off"

  test "a part may be empty (a text that leaves it out)":
    discard trLoad("de", [("de", De)])
    check tr("Imports updated in 2 file(s)") == "Importe in 2 Datei(en) erneuert"
    check tr("Imports updated in 2 file(s) — by hand: a.nim") == "Importe in 2 Datei(en) erneuert — by hand: a.nim"

  test "a sign before or after the words: they are looked up without it":
    discard trLoad("de", [("de", De)])
    check tr("▶ Save") == "▶ Speichern"
    check tr("Save ✓") == "Speichern ✓"
    check tr("● Saved 3 files") == "● 3 Dateien gespeichert"
    check tr("→ Nothing here") == "→ Nothing here"
    check tr("Save. Now") == "Save. Now"                   # (a word with a full stop: not a sign)
    check tr("(on) Save") == "(on) Save"
    discard trLoad("pseudo", [])
    check tr("▶ Save") == "▶ ⟦Save⟧"
    check tr("agent ✓") == "⟦agent⟧ ✓"

  test "$$ is a dollar sign":
    discard trLoad("de", [("de", De)])
    check tr("Costs $5") == "Kostet 5 $"
    check tr("Price: $12") == "Preis: 12 $"

  test "an entry with too few letters is not a pattern":
    discard trLoad("de", [("de", De)])
    check tr("a: b") == "a: b"

  test "pseudo: each text marked once":
    check trLoad("pseudo", []).len == 0
    check trOn
    check tr("Save") == "⟦Save⟧"
    check tr(tr("Save")) == "⟦Save⟧"
    check tr(" Save ") == " ⟦Save⟧ "
    check tr("→ 12") == "→ 12"                              # (no letters: nothing to translate)
    check trf("Saved $1 files", 2) == "⟦Saved 2 files⟧"
    check trLanguage() == "pseudo"

  test "the language of the system's settings":
    putEnv("LC_ALL", "")
    putEnv("LC_MESSAGES", "")
    putEnv("LANG", "de_AT.UTF-8")
    check trLangOfEnv() == "de_AT"
    check trCandidates("de_AT") == @["de_AT", "de"]
    check trCandidates("pt-BR") == @["pt_BR", "pt"]
    check trLoad("auto", [("de", De)]).len == 0
    check trLanguage() == "de"
    check tr("Save") == "Speichern"
    putEnv("LANG", "C")
    check trLangOfEnv() == ""
    discard trLoad("auto", [("de", De)])
    check not trOn

  test "a file of yours over ned's, and one ned does not have":
    let d = getTempDir() / "ned-ti18n"
    createDir(d)
    writeFile(d / "de.json", """{"Save": "Sichern", "Open": "Öffnen"}""")
    writeFile(d / "xx.json", """{"@language": "Xish", "Save": "Xave"}""")
    check trLoad("de", [("de", De)], d).len == 0
    check tr("Save") == "Sichern"
    check tr("Open") == "Öffnen"
    check tr("File") == "Datei"
    check trLoad("xx", [("de", De)], d).len == 0
    check trLanguageName() == "Xish"
    check tr("Save") == "Xave"
    check tr("File") == "File"
    removeDir(d)

  test "what is said when a catalogue cannot be read":
    let d = getTempDir() / "ned-ti18n-bad"
    createDir(d)
    writeFile(d / "de.json", "{ not json")
    let why = trLoad("de", [("de", De)], d)
    check why.len == 1
    check "de.json" in why[0]
    check tr("Save") == "Speichern"                        # (ned's own still there)
    check trLoad("de", [("de", "[1, 2]")]).len == 1
    removeDir(d)

  test "a plugin's catalogue added to the language in use":
    discard trLoad("de", [("de", De)])
    check trLoadText("""{"Containers": "Container", "Stopped $1": "$1 angehalten"}""") == ""
    check tr("Containers") == "Container"
    check tr("Stopped web") == "web angehalten"
    check tr("Save") == "Speichern"
