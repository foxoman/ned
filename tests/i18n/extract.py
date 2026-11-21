#!/usr/bin/env python3
"""The texts ned shows, for translators (6.55): i18n/template.json, every one of them in English with "" beside it.

Taken from the source — the calls that show a text (info, warn, error, toast, mi, act, openActions, openDialog,
askConfirm, the forms' fields, button, drawFrame …) and tr(…) / trf(…) — and, with --ned, the texts ned makes from
its tables (`ned --i18n-strings`: the commands, the settings, the menu bar). A text built with & becomes one with $1 …
for its parts that change: `info("Saved " & name & " (" & $n & " lines)")` → "Saved $1 ($2 lines)".

  extract.py [--ned ./ned]               write i18n/template.json
  extract.py [--ned ./ned] --check       the template is up to date (CI): what is missing or no longer used
  extract.py [--ned ./ned] --lang ar     check a translation (i18n/ar.json, or a path): JSON, entries missing,
                                         entries the template no longer has, $n not the same as the English
  extract.py --where "Saved $1"          where a text of the template comes from

Nothing here runs ned's code but `ned --i18n-strings`."""
import json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TEMPLATE = os.path.join(ROOT, "i18n", "template.json")

# the calls that show a text: name → the argument places that are shown (0 the first; ("kw", n): by keyword or at n)
SINKS = {
    "info": [0], "warn": [0], "error": [0], "setMsg": [0], "popupMsg": [0], "notifyDesktop": [0],
    "toast": [0, ("actLabel", 2)],
    "mi": [0], "msub": [0], "mc": [("label", 1)], "ctxCopy": [0],
    "act": [0, 1], "openActions": [0], "openPicker": [1], "openPrompt": [1], "tsOpen": [0],
    "openDialog": [0, 1, "buttons2"], "askConfirm": ["confirm0"],
    "newForm": [0, ("intro", 1)],
    "addCheck": [2, ("help", 4)], "addChoice": [2, ("help", 5), ("labels", 6)], "addText": [2, ("placeholder", 4), ("help", 5)],
    "addNumber": [2, ("help", 4)], "addNote": [1], "addHeader": [1], "addLink": [1, ("help", 3)], "addButton": [1],
    "button": [2, ("tip", 4)], "pill": [2, ("tip", 4)], "region": [("tip", 5)], "drawFrame": [("title", 6)],
    "drawBox": [("title", 4)],
    "sideItem": [0, ("detail", 3)], "toolLine": [1], "askText": [0], "askConfirmText": [0], "askPath": [0],
    "openScratch": [0], "paneViewBuf": [0], "openMultibuffer": [0], "openMultibufferOf": [0],
    "gitRun": [1], "gitShell": [1], "gitNet": [1], "gitAsk": [0], "pickBranch": [0], "showReferences": [0],
    "toolOutput": [0],
    "tr": [0], "tx": [0], "trf": ["raw0"],
}
# methods: f.addCheck(…) — the receiver is the first argument
METHODS = {"addCheck", "addChoice", "addText", "addNumber", "addNote", "addHeader", "addLink", "addButton"}
# object constructors whose fields are shown
FIELDS = {"PickItem": ["detail"], "SideItem": ["text", "detail"], "MenuItem": ["label"], "PanelLine": ["text"],
          "TsEntry": ["label", "detail"], "ResetPart": ["label", "what"]}
# a file's own routines that show a text (the list of finders: add(label, detail, action, help))
FILE_SINKS = {"telescope.nim": {"add": [0, 3]}}
# ned's own plugins (plugins/): the plugin library's routines that show a text
PLUGIN_SINKS = {"command": [0], "settingDef": [2], "message": [0], "toast": [0], "warn": [0], "pick": [0], "ask": [0],
                "confirm": [0], "status": [0], "progress": [0], "view": [0], "newTab": [0], "showKeyHints": [0]}

STR_RE = re.compile(r'r?"""(?:.|\n)*?"""(?!")|r"(?:[^"]|"")*"|"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)\'')


def unescape(lit):
    """a Nim string literal's text"""
    if lit.startswith('"""'): return lit[3:-3].lstrip("\n") if lit.startswith('"""\n') else lit[3:-3]
    if lit.startswith('r"""'): return lit[4:-3]
    if lit.startswith('r"'): return lit[2:-1].replace('""', '"')
    body, out, i = lit[1:-1], [], 0
    esc = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "e": "\x1b", "a": "\a", "0": "\0"}
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            if n in esc: out.append(esc[n]); i += 2
            elif n == "x": out.append(chr(int(body[i + 2:i + 4], 16))); i += 4
            elif n == "u" and body[i + 2] == "{":
                e = body.index("}", i); out.append(chr(int(body[i + 3:e], 16))); i = e + 1
            elif n == "u": out.append(chr(int(body[i + 2:i + 6], 16))); i += 6
            elif n.isdigit():
                j = i + 1
                while j < len(body) and body[j].isdigit(): j += 1
                out.append(chr(int(body[i + 1:j]))); i = j
            else: out.append(n); i += 2
        else: out.append(c); i += 1
    s = "".join(out)
    # (bytes written as \xHH: UTF-8 as ned has it)
    try: s = s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError): pass
    return s


def skip_str(src, i):
    """the index after the string or character literal at i (i itself when there is none)"""
    m = STR_RE.match(src, i)
    if m and (src[i] != "'" or not (i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"))): return m.end()
    return i


def args_of(src, i):
    """the arguments of the call whose ( is at i, as source texts (top-level commas), and the index after its )"""
    depth, start, out, j = 0, i + 1, [], i
    while j < len(src):
        c = src[j]
        if c in "\"'" or (c == "r" and src[j + 1:j + 2] == '"'):
            k = skip_str(src, j + (1 if c == "r" else 0) if c == "r" else j)
            if c == "r": k = skip_str(src, j) if STR_RE.match(src, j) else j + 1
            if k > j: j = k; continue
        if c == "#" and not src.startswith("#[", j):
            while j < len(src) and src[j] != "\n": j += 1
            continue
        if c in "([{": depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                out.append(src[start:j]); return out, j + 1
        elif c == "," and depth == 1:
            out.append(src[start:j]); start = j + 1
        j += 1
    return out, j


def split_amp(expr):
    """an expression's parts joined by & at the top level"""
    parts, depth, start, j = [], 0, 0, 0
    while j < len(expr):
        c = expr[j]
        k = skip_str(expr, j) if c in "\"'" or (c == "r" and expr[j + 1:j + 2] == '"') else j
        if k > j: j = k; continue
        if c in "([{": depth += 1
        elif c in ")]}": depth -= 1
        elif c == "&" and depth == 0 and not expr[j + 1:j + 2] == "=":
            parts.append(expr[start:j]); start = j + 1
        j += 1
    parts.append(expr[start:])
    return [p.strip() for p in parts]


def is_lit(p):
    """the part is one string literal"""
    m = STR_RE.fullmatch(p)
    return m is not None and not p.startswith("'")


def template_of(expr, raw=False):
    """the text an expression shows, with $1 … for the parts that change; None when it shows nothing to translate"""
    expr = expr.strip()
    if "=" in expr and re.match(r"^[A-Za-z_]\w*\s*=[^=]", expr): expr = expr.split("=", 1)[1].strip()  # (kw = value)
    m = re.match(r'^(fmt|&)("(?:[^"\\]|\\.)*")$', expr)
    if m:                                             # fmt"…{x}…": its {} parts change
        text = re.sub(r"\{[^{}]*\}", "\x00", unescape(m.group(2)))
        pieces = text.split("\x00")
        out = pieces[0].replace("$", "$$")
        for n, p in enumerate(pieces[1:], 1): out += "$%d" % n + p.replace("$", "$$")
        return out if good(out) else None
    if raw:
        return unescape(expr) if is_lit(expr) and good(unescape(expr)) else None
    pct = re.match(r'^("(?:[^"\\]|\\.)*")\s*%\s*', expr)
    if pct: return unescape(pct.group(1)) if good(unescape(pct.group(1))) else None
    parts = split_amp(expr)
    out, n, last_slot = "", 0, False
    for p in parts:
        while p.startswith("(") and p.endswith(")") and is_lit(p[1:-1].strip()): p = p[1:-1].strip()
        if is_lit(p):
            out += unescape(p).replace("$", "$$"); last_slot = False
        else:
            tm = re.match(r'^tr\((".*")\)$', p)
            if tm and is_lit(tm.group(1)):
                out += unescape(tm.group(1)).replace("$", "$$"); last_slot = False
                continue
            if not last_slot:
                n += 1
                if n > 9: return None
                out += "$%d" % n
            last_slot = True
    return out if good(out) else None


def meta(k):
    """a catalogue's own entry ("@language"), not a text: @ and a word"""
    return re.fullmatch(r"@\w+", k) is not None


# words of fewer than three letters that are texts of their own: the dialogs' buttons, menus, a tooltip
SHORT = {"No", "OK", "AI", "Up"}      # (not "Go": the menu, and the language too)


def good(t, least=3):
    """worth translating: three letters of text at least (not "$1: $2"), or one of the SHORT words, and not a key, a
    path or code"""
    if t is None: return False
    if t.strip() in SHORT: return True
    lit = re.sub(r"\$\d", "", t)
    if sum(1 for c in lit if c.isalpha()) < least: return False
    if re.fullmatch(r"[a-z]+(\.[a-zA-Z]+)+", t.strip()): return False        # (a setting's key)
    return True


def confirm_parts(text):
    """askConfirm's question as the dialog shows it: its body and its buttons (as dialogs.nim's parseConfirm)"""
    out = []
    if text.endswith("(y/n)"):
        return [text[:-5].strip(), "Yes", "No"]
    i = text.find(" (")
    dash = text.find(" — (")
    if dash >= 0 and (i < 0 or dash < i): i = dash
    if i < 0: return [text, "OK", "Cancel"]
    out.append(text[:i].replace("—", "").strip(" -"))
    rest = text[i:]
    k = 0
    while k < len(rest):
        if rest[k] == "(" and k + 2 < len(rest) and rest[k + 2] == ")":
            key = rest[k + 1]
            e = k + 3
            while e < len(rest) and rest[e] not in "(,": e += 1
            label = key.upper() + rest[k + 3:e].replace("—", "").strip(" ,")
            if len(label) == 1: label = {"y": "Yes", "n": "No", "c": "Cancel"}.get(key, label)
            out.append(label)
            k = e
        else: k += 1
    return out + ["Save", "Save all", "Don't save", "Confirm", "Unsaved changes", "Are you sure?"]


def unparen(e):
    """an expression without brackets around the whole of it"""
    e = e.strip()
    while e.startswith("(") and e.endswith(")"):
        depth, j = 0, 0
        while j < len(e):
            c = e[j]
            k = skip_str(e, j) if c in "\"'" or (c == "r" and e[j + 1:j + 2] == '"') else j
            if k > j: j = k; continue
            if c in "([{": depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0: break
            j += 1
        if j != len(e) - 1: break
        e = e[1:-1].strip()
    return e


def if_branches(expr):
    """the values an `if … : A elif … : B else: C` expression may have, each an expression of its own (an expression
    that is not one: itself)"""
    e = unparen(expr)
    if not e.startswith("if "): return [expr]
    out, depth, state, start, j = [], 0, "cond", 0, 3
    while j < len(e):
        c = e[j]
        k = skip_str(e, j) if c in "\"'" or (c == "r" and e[j + 1:j + 2] == '"') else j
        if k > j: j = k; continue
        if c in "([{": depth += 1
        elif c in ")]}": depth -= 1
        elif depth == 0:
            if state == "cond" and c == ":":
                state, start = "val", j + 1
            elif state == "val" and c.isspace():
                m = re.match(r"\s+elif\s", e[j:])
                if m:
                    out.append(e[start:j]); state = "cond"; j += m.end(); continue
                m = re.match(r"\s+else\s*:", e[j:])
                if m:
                    out.append(e[start:j]); state = "else"; start = j + m.end(); j = start; continue
        j += 1
    if state in ("val", "else"): out.append(e[start:])
    res = []
    for b in out: res.extend(if_branches(b))
    return res or [expr]


def words_in_parts(expr):
    """the words an expression's changing parts may be: the texts of `(if on: "on" else: "off")` — translated where
    they are filled in"""
    out = []
    for p in split_amp(expr):
        if is_lit(p) or not re.search(r"\bif\b", p): continue
        for lit in STR_RE.findall(p):
            if not lit.startswith("'") and good(unescape(lit).strip(), 2): out.append(unescape(lit).strip())
    return out


def scan_file(path, found):
    """the texts one source file shows, into `found` (text → where)"""
    src = open(path, encoding="utf-8").read()
    rel = os.path.relpath(path, ROOT)
    def add(t, at, least=3):
        t = t.strip(" ") if t else t          # (tr looks a text up without the spaces around it)
        if t and good(t, least): found.setdefault(t, []).append("%s:%d" % (rel, src.count("\n", 0, at) + 1))
    sinks = dict(SINKS, **FILE_SINKS.get(os.path.basename(path), {}))
    if rel.startswith("plugins" + os.sep): sinks.update(PLUGIN_SINKS)
    for m in re.finditer(r"(?:(?<![\w.])|(?<=\w)(?=\.))(\.?)([A-Za-z_]\w*)\s*\(", src):
        dot, name = m.group(1), m.group(2)
        if name in FIELDS and FIELDS[name]:
            args, _ = args_of(src, m.end() - 1)
            for a in args:
                kv = re.match(r"^\s*(\w+)\s*:\s*(.*)$", a, re.S)
                if kv and kv.group(1) in FIELDS[name]: add(template_of(kv.group(2)), m.start())
            continue
        if name not in sinks: continue
        if dot and name not in METHODS: continue
        args, _ = args_of(src, m.end() - 1)
        if dot: args = ["<receiver>"] + args
        for spec in sinks[name]:
            if spec == "confirm0":
                if args and is_lit(split_amp(args[0])[0]) or args:
                    t = template_of(args[0]) if args else None
                    if t:
                        for p in confirm_parts(t): add(p, m.start())
                continue
            if spec == "buttons2":
                if len(args) > 2:
                    for lit in STR_RE.findall(args[2]):
                        if not lit.startswith("'"): add(unescape(lit), m.start())
                continue
            if spec == "raw0":
                if args: add(template_of(args[0], raw=True), m.start())
                continue
            kw, pos = (spec if isinstance(spec, tuple) else (None, spec))
            val = None
            if kw:
                for a in args:
                    kv = re.match(r"^\s*%s\s*=\s*(.*)$" % kw, a, re.S)
                    if kv: val = kv.group(1)
            if val is None and pos < len(args) and not re.match(r"^\s*\w+\s*=[^=]", args[pos]): val = args[pos]
            if val is None: continue
            if kw == "labels" or val.strip().startswith("@["):
                for lit in STR_RE.findall(val):
                    if not lit.startswith("'"): add(unescape(lit), m.start())
                continue
            for v in if_branches(val):
                add(template_of(v), m.start())
                for w in words_in_parts(v): add(w, m.start(), 2)
    # the command syntax: info "Saved", toast "…"
    words = "info|warn|error|toast" + ("|command|message|status|progress|view|confirm|ask" if
                                        rel.startswith("plugins" + os.sep) else "")
    # (a statement of its own: at the start of a line or after a ':' — not a word inside a string: "(error " & …)
    for m in re.finditer(r'(?:^|(?<=:))[ \t]*(%s)[ ]+("(?:[^"\\\n]|\\.)*")' % words, src, re.M):
        add(template_of(m.group(2)), m.start())


HELP_KEYS = {"Ctrl", "Alt", "Shift", "Enter", "Tab", "Space", "Esc", "PgUp", "PgDn", "Home", "End", "Del", "Ins",
             "Backspace", "Insert", "Delete", "Cmd", "Meta"}


def help_key_words(key):
    """the help's key column has words to translate ("Right click", "Palette ›"), not only keys ("Ctrl+Alt+←"); a
    command or a file name ("/server:prompt", ".editorconfig") stays as it is"""
    if key[:1] in "/.": return False
    return any(w not in HELP_KEYS for w in re.findall(r"[A-Za-z]{3,}", key))


def scan_help(path, found):
    """the key-bindings help (popups.nim's HelpLines): each line's description, as helpRows splits it from its keys,
    and the key column's words"""
    src = open(path, encoding="utf-8").read()
    i = src.find("const HelpLines = [")
    if i < 0: return
    e = src.find("\n]", i)
    rel = os.path.relpath(path, ROOT)
    for m in STR_RE.finditer(src, i, e):
        l = unescape(m.group(0))
        if not l: continue
        if l == l.upper() and l[0].isalpha(): t = l
        elif l[0] != " ":
            k = l.find("  ")
            t = l[k:].lstrip() if 0 < k <= 21 else l
            if 0 < k <= 21 and help_key_words(l[:k]):
                found.setdefault(l[:k].replace("$", "$$"), []).append("%s:%d" % (rel, src.count("\n", 0, m.start()) + 1))
        else: t = l.strip()
        if good(t): found.setdefault(t.replace("$", "$$"), []).append("%s:%d" % (rel, src.count("\n", 0, m.start()) + 1))


def scan_source():
    """every text the source shows: text → [file:line]"""
    found = {}
    dirs = [os.path.join(ROOT, "src"), os.path.join(ROOT, "plugins")]
    for d in dirs:
        for base, _, files in os.walk(d):
            if os.sep + "lib" + os.sep in base + os.sep and "plugins" in base and base.endswith("lib"): pass
            for f in sorted(files):
                if f.endswith((".nim", ".nims")) and not f.endswith("i18n.nim"):
                    scan_file(os.path.join(base, f), found)
                    if f == "popups.nim": scan_help(os.path.join(base, f), found)
    return found


def from_ned(ned):
    """the texts ned makes from its tables (`ned --i18n-strings`)"""
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(os.environ.get("TMPDIR", "/tmp"), "ned-i18n-cfg"))
    out = subprocess.run([ned, "--i18n-strings"], capture_output=True, text=True, env=env, timeout=120)
    if out.returncode != 0: sys.exit("ned --i18n-strings: " + out.stderr.strip())
    return {t.strip(" "): ["(ned's tables)"] for t in json.loads(out.stdout) if good(t)}


def build(ned):
    """the template's texts in order: the tables', then the source's (by file)"""
    found = from_ned(ned) if ned else {}
    for t, w in scan_source().items(): found.setdefault(t, []).extend(w)
    return found


def main():
    a = sys.argv[1:]
    ned = a[a.index("--ned") + 1] if "--ned" in a else None
    if "--where" in a:
        t = a[a.index("--where") + 1]
        for w in build(ned).get(t, ["(not in the template)"]): print(w)
        return
    found = build(ned)
    tpl = {t: "" for t in found}
    if "--lang" in a:
        p = a[a.index("--lang") + 1]
        path = p if os.path.exists(p) else os.path.join(ROOT, "i18n", p + ".json")
        try: cat = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError) as e: sys.exit("%s: %s" % (path, e))
        if not isinstance(cat, dict): sys.exit(path + ": not a JSON object of English text → translation")
        done = {k: v for k, v in cat.items() if not meta(k) and isinstance(v, str) and v}
        missing = [t for t in tpl if t not in done]
        unused = [k for k in done if k not in tpl]
        bad = []
        for k, v in done.items():
            # (a translation may leave a part out — an English plural ending: "$1 file$2" → "Datei(en): $1" — but
            # not add one, use one twice, or lose a $$)
            tv = re.findall(r"\$\d", v)
            if len(tv) != len(set(tv)) or not set(tv) <= set(re.findall(r"\$\d", k)) or k.count("$$") != v.count("$$"):
                bad.append((k, v))
        print("%s: %d of %d translated (%d%%)" % (os.path.basename(path), len(tpl) - len(missing), len(tpl),
              (len(tpl) - len(missing)) * 100 // max(1, len(tpl))))
        for k, v in bad: print("  $n added, twice or $$ lost: %r → %r" % (k, v))
        if unused: print("  %d no longer in ned (they can go): %s" % (len(unused), ", ".join(map(repr, unused[:10]))))
        if "--missing" in a:
            for t in missing: print("  missing: %r" % t)
        sys.exit(1 if bad else 0)
    text = json.dumps(tpl, ensure_ascii=False, indent=1) + "\n"
    if "--check" in a:
        old = json.load(open(TEMPLATE, encoding="utf-8")) if os.path.exists(TEMPLATE) else {}
        new_ = [t for t in tpl if t not in old]
        gone = [t for t in old if t not in tpl]
        if new_ or gone:
            print("i18n/template.json is not up to date (python3 tests/i18n/extract.py --ned ./ned):")
            for t in new_[:20]: print("  new: %r  (%s)" % (t, found[t][0]))
            for t in gone[:20]: print("  gone: %r" % t)
            sys.exit(1)
        print("i18n/template.json: up to date, %d texts" % len(tpl))
        return
    open(TEMPLATE, "w", encoding="utf-8").write(text)
    print("i18n/template.json: %d texts" % len(tpl))


if __name__ == "__main__":
    main()
