# Translating ned

ned's menus, palette, messages, dialogs, docks, settings and help can be shown in your language. A translation is
one file, `i18n/<code>.json`: a JSON object from each English text to yours. No programming is needed, and a file
that is only partly done already works: what it does not have stays in English.

## Built in

| Code | Language | | Code | Language |
|---|---|---|---|---|
| `de` | Deutsch | | `pl` | Polski |
| `fr` | Français | | `sv` | Svenska |
| `es` | Español | | `cs` | Čeština |
| `it` | Italiano | | `el` | Ελληνικά |
| `pt` | Português (Portugal) | | `ru` | Русский |
| `nl` | Nederlands | | `zh_CN` | 简体中文 |

`zh_CN` was made by lyongji ([#12](https://github.com/foxoman/ned/pull/12)), in 6.57. The others were written by
Claude (Anthropic's AI model) for 6.56, not by native speakers. They are complete, but a word may read oddly or a
term may not be the one your language's programmers use. Corrections are welcome: change
the text in `i18n/<code>.json` and send a pull request, or open an issue with the English text and the better words.
To improve one, start from its file instead of the template.

## Start

1. Take `i18n/template.json`: every text ned shows, in English, with `""` beside it. It is made from the source,
   so it has them all.
2. Copy it under your language's code, the one `LANG` uses: `ar.json`, `de.json`, `zh_CN.json`, `pt_BR.json`
   (a region only when it matters: `pt_BR` is used for Brazil and `pt` for the rest).
3. Put your language's name, in your language, first: `"@language": "العربية"`. The language list shows it.
4. Write each translation in its `""`. Leave one empty to keep the English for now.

```json
{
 "@language": "Deutsch",
 "Save": "Speichern",
 "Saved $1 files": "$1 Dateien gespeichert",
 "Open file…": "Datei öffnen…",
 "Command palette": ""
}
```

## Try it as you go

- Put your file in `~/.config/ned/i18n/` (ned's settings folder) and choose it in **Palette › Language…**, or set
  `"ui.language": "de"` in the settings. `auto`, the default, takes your system's language (`LANG`).
- After an edit, **Palette › Language: reload the translations** shows it at once.
- `"ui.language": "pseudo"` shows every text ned can translate between ⟦ and ⟧. A text on the screen without them
  is one ned does not let you translate yet: please say so in an issue.

## Texts with parts that change

Some texts have parts ned fills in — a file's name, a number. The template writes them `$1`, `$2` … :
`"Deleted $1 recovery file(s)"`. Keep each `$n` in your translation; you may put them in any order your language
needs (`"Move $1 to $2"` → `"$2: $1 verschieben"`). `$$` stands for a dollar sign itself.

A part may be left out when your language does not need it. Most often it is an English plural ending:
`"Saved $1 file$2"` fills `$2` with `s` or nothing, and a translation can drop it and write a form that fits any
number (`"Gespeichert: $1 Datei(en)"`). A translation may not add a part the English does not have, or use one twice.

A part is sometimes an English word ned chose (`"$1 (on)"`): the template has that word too, and translating it
translates it everywhere. Only ned's own words are (they are listed in `i18n/PARTS`): a part that is a name — a file
called `test`, a branch called `build` — stays as it is.

## What is translated

- The menu bar and every menu, the command palette's commands, the key bindings' names.
- Messages, notifications, questions and their buttons, forms, the settings window (sections, names and the
  description of each setting).
- The docks and panels (headings, empty states, buttons), the status bar, the welcome page, the tips.
- A plugin's texts: ned's own plugins are in the template; another plugin can have an `i18n/<code>.json` of its own
  beside its source, which ned reads with yours.

Not translated: your files and their code, names from your project, what compilers, language servers and AI models
say — and the problems ned's own engines find, which read as a compiler's —, what ned asks an AI model, the reports
ned writes for you to paste into an issue (*Check setup*, the performance report), the Nim tour's lessons (they are
Nim files), the documentation (`docs/`), and what ned prints on the command line (`ned --help`, `--lint` …).

## Check it

```sh
python3 tests/i18n/extract.py --lang de             # i18n/de.json (or a path): how much is done
python3 tests/i18n/extract.py --lang de --missing   # … and each text still to do
```

It says how many texts are done, a `$n` your translation added or used twice, and texts ned no longer has (they
can go).

## Send it

A pull request that adds `i18n/<code>.json` and your code on a line of `i18n/LANGUAGES`: from the next release it is
built into ned, and anyone whose system speaks your language sees it. Attaching the file to an issue is fine too.

Each release adds and changes some texts: `--lang … --missing` lists the new ones.

## Right-to-left languages

ned lays out its interface from the left, as the terminal does. A translation into Arabic, Persian or Hebrew works,
and each text reads as your terminal shows right-to-left text.

## For developers: keeping ned translatable

Every text shown to the person goes through `tr` (`src/ned/core/i18n.nim`). The routines that show text call it
themselves — `info`, `warn`, `error`, `toast`, `mi`, `act` / `openActions`, `openDialog`, `askConfirm`, the forms'
fields and buttons, `button`, `pill`, a `drawFrame` or `drawBox` title, a prompt's label, a picker's title and
details, a dock row (`sideItem`) — so a text passed to them is ready. A text drawn some other way:

- `tr("Nothing opened yet")` where it is drawn;
- `trf("Saved $1 files", n)` for one with parts (not `"Saved " & $n & " files"` drawn as it is);
- `tx("…")` in a constant or a table, and `tr(…)` where that text is shown;
- `dataText(name)` for a name passed whole to one of those routines — a file, a branch, a commit's subject, git's or
  a server's words — and `actData(label, detail, …)` for a picker's entry made of them: shown as they are (a branch
  called `test` is not the word "test").

Then `python3 tests/i18n/extract.py --ned ./ned` writes the template again (CI checks it is up to date). A run of the
UI suite in the pseudo language finds what was missed: `tests/i18n/untranslated.py` says how.
