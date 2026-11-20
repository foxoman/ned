#!/usr/bin/env python3
"""What is not ready for translation yet (6.55), from a run of the UI suite in the pseudo language:

  NED_UI_PSEUDO=1 NED_UI_SCREENS=/tmp/screens.txt NED_I18N_RECORD=/tmp/seen.txt python3 tests/ui/run.py ./ned
  python3 tests/i18n/untranslated.py /tmp/screens.txt /tmp/seen.txt

  1. texts that came to tr but that i18n/template.json has not (a translator never sees them): the source makes
     them some way extract.py does not follow — mark them with tr(…) / trf(…) where they are made
  2. words on the screens outside ⟦ ⟧ (drawn without tr): the most frequent first — a file's text and code are
     among them, the rest is to be marked

Either list empty is the aim; --max N shows N of each (default 80)."""
import json, os, re, sys, collections

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def patterns(tpl):
    """the template's texts as regular expressions (those with $n), and the plain ones as a set"""
    plain, pats = set(), []
    for k in tpl:
        if re.search(r"\$\d", k):
            parts = re.split(r"\$\d", k.replace("$$", "\x00"))
            rx = "(.*?)".join(re.escape(p.replace("\x00", "$")) for p in parts)     # (a part may be empty, as in tr)
            pats.append(re.compile("^" + rx + "$", re.S))
        else: plain.add(k.replace("$$", "$"))
    return plain, pats


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    n = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 80
    if len(a) < 2: sys.exit(__doc__)
    screens, seen = a[0], a[1]
    tpl = json.load(open(os.path.join(ROOT, "i18n", "template.json"), encoding="utf-8"))
    plain, pats = patterns(tpl)
    # 1. through tr, not in the template
    miss, done = [], set()
    for l in open(seen, encoding="utf-8"):
        try: s = json.loads(l)
        except ValueError: continue
        t = s.strip(" ")
        if not t or t in done or t.startswith("⟦") or t in plain or not re.search(r"[A-Za-z]{3}", t): continue
        done.add(t)
        if any(p.match(t) for p in pats): continue
        # (a file's or a folder's name, a branch, a number: data, not a text of ned's)
        if re.fullmatch(r"[\w./~⎇▸ +-]*", t) and " " not in t.strip(): continue
        if t.startswith(("/", "~/", "⎇ ")): continue
        # (a key or keys: Ctrl+Alt+↑, Alt+. / F12 — and a symbol beside a word that is there: "▶ running")
        if not re.search(r"[A-Za-z]{3}", re.sub(r"\b(Ctrl|Alt|Shift|Cmd|Meta|Enter|Space|Tab|Esc|PgUp|PgDn|Home|End|"
                                               r"Backspace|Delete|Insert)\b", "", t)): continue
        core = re.sub(r"""^[^\w$(\["'“]{1,4} | [^\w$)\]"'”]{1,4}$""", "", t)
        if core != t and (core.startswith("⟦") or core in plain or any(p.match(core) for p in pats)): continue
        miss.append(t)
    miss.sort(key=lambda t: -len(t.split()))
    print("1. %d texts came to tr that the template has not (the longest first):" % len(miss))
    for t in miss[:n]: print("   %r" % t)
    # 2. on the screen without ⟦ ⟧
    words = collections.Counter()
    text = open(screens, encoding="utf-8", errors="replace").read()
    for scr in text.split("\x0c"):
        for line in scr.split("\n"):
            line = re.sub(r"⟦[^⟧]*⟧", "  ", line)
            # (a marked text wrapped in a box: its start on one row, its end on the next — up to the frame)
            line = re.sub(r"⟦[^│]*", "  ", line)
            line = re.sub(r"(^|│)[^│⟧]*⟧", "  ", line)
            # (the editor's lines: a number, then code — skipped; and the box-drawing frames' insides kept)
            if re.match(r"^\s*(\d+|↪)\s{2}", line): continue
            for m in re.finditer(r"[A-Za-z][A-Za-z'’]+(?:[ ,.:—-]{1,3}[A-Za-z][A-Za-z'’]+){1,}", line):
                words[m.group(0).strip()] += 1
    print("\n2. %d runs of words on the screens are not marked (the most frequent first):" % len(words))
    for w, c in words.most_common(n): print("   %5d  %s" % (c, w))


if __name__ == "__main__":
    main()
