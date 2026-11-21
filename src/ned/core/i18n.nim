## The interface in other languages (6.55): every text ned shows goes through `tr`, which looks it up in the
## catalogue of the language chosen (`ui.language`) and gives the English text when there is none. A catalogue is a
## JSON object from the English text to the translation (`i18n/<lang>.json`, built into ned; a file of the same name
## in `~/.config/ned/i18n` comes first: a translation being made). A text with a part that changes ("Saved 3 files")
## is written in a catalogue with $1 … $9 for those parts ("Saved $1 files"), and found whole: the translation may put
## them in another order. `$$` is a dollar sign. The language "pseudo" shows each text that went through `tr` between
## ⟦ and ⟧: a text on the screen without them is not ready for translation yet. See TRANSLATING.md.
## A module of its own: the unit tests use it, and nedls may.

import std/[json, os, strutils, tables]

type
  TrPattern = object
    ## a catalogue entry with parts that change: its literal pieces (lits[0] before the first part, lits[^1] after
    ## the last), which part each place is ($1 → 1), and the translation
    lits: seq[string]
    slots: seq[int]
    to: string

var
  trOn* = false                       # a language with a catalogue (or "pseudo") is in use: `tr` looks texts up
  trPseudo = false
  trCode = ""                         # the language in use ("" English)
  trName = ""                         # its name in itself (the catalogue's "@language")
  trExact: Table[string, string]      # entries without $n
  trRaw: Table[string, string]        # entries with $n, by their key as written (trf's)
  trPats: seq[TrPattern]
  trByHead: Table[string, seq[int]]   # patterns by their first bytes (up to 4), and by their last (when they end
  trByTail: Table[string, seq[int]]   #   with text); the rest (a part first and last) in trLoose
  trLoose: seq[int]
  trMemo: Table[string, string]       # texts with parts, looked up already
  trSeen: Table[string, bool]         # (NED_I18N_RECORD: the texts asked for, each written once to that file)
  trRecord: File
  trRecording = -1                    # -1 not known yet, 0 no, 1 yes

const TrHead = 4

proc trUnescape(s: string): string =
  ## a catalogue key's or translation's text with `$$` as one `$`
  s.replace("$$", "$")

proc trParse(key: string): (seq[string], seq[int]) =
  ## a key's literal pieces and its parts' numbers: "Saved $1 files" → (["Saved ", " files"], [1])
  var lits = @[""]
  var slots: seq[int]
  var i = 0
  while i < key.len:
    if key[i] == '$' and i + 1 < key.len and key[i + 1] == '$':
      lits[^1].add '$'
      i += 2
    elif key[i] == '$' and i + 1 < key.len and key[i + 1] in {'1' .. '9'}:
      slots.add ord(key[i + 1]) - ord('0')
      lits.add ""
      i += 2
    else:
      lits[^1].add key[i]
      inc i
  (lits, slots)

proc trClear() =
  ## no catalogue: English
  trExact.clear()
  trRaw.clear()
  trPats.setLen(0)
  trByHead.clear()
  trByTail.clear()
  trLoose.setLen(0)
  trMemo.clear()
  trName = ""

proc trMeta(key: string): bool =
  ## a catalogue's own entry, not a text: @ and a word ("@language"); "@file @diff — context" is a text
  if key.len < 2 or key[0] != '@': return false
  for c in key[1 .. ^1]:
    if not (c.isAlphaNumeric or c == '_'): return false
  true

proc trAdd(key, to: string) =
  ## one entry of a catalogue (an empty translation is not one: the English text stays)
  if key.len == 0 or to.len == 0 or trMeta(key): return
  if '$' notin key:
    trExact[key] = to
    return
  let (lits, slots) = trParse(key)
  trRaw[key] = to
  if slots.len == 0:
    trExact[trUnescape(key)] = to
    return
  var letters = 0
  for l in lits:
    for c in l:
      if c.isAlphaAscii or c.ord >= 0x80: inc letters
  if letters < 3: return                    # ("$1: $2" would be any text at all)
  let k = trPats.len
  trPats.add TrPattern(lits: lits, slots: slots, to: to)
  if lits[0].len > 0: trByHead.mgetOrPut(lits[0][0 ..< min(TrHead, lits[0].len)], @[]).add k
  elif lits[^1].len > 0: trByTail.mgetOrPut(lits[^1][max(0, lits[^1].len - TrHead) .. ^1], @[]).add k
  else: trLoose.add k

proc trMatch(p: TrPattern, s: string, caps: var seq[string]): bool =
  ## whether `s` is the pattern's text with something in each part; the parts found in `caps`, by their number. A
  ## part may be empty (a part some texts leave out: "Saved $1 files$2" for "Saved 3 files" and "Saved 3 files — 1
  ## by hand"); it takes as little as it can, and more when the rest does not match then
  if not s.startsWith(p.lits[0]) or not s.endsWith(p.lits[^1]) or s.len < p.lits[0].len + p.lits[^1].len: return
  caps.setLen(10)
  proc go(i, at: int, caps: var seq[string]): bool =
    ## parts i… from byte `at`
    if i == p.slots.len: return at == s.len
    let next = p.lits[i + 1]
    if i == p.slots.len - 1:
      # the last part: up to the text after it, which ends the string
      let e = s.len - next.len
      if e < at: return false
      caps[p.slots[i]] = s[at ..< e]
      return true
    var j = s.find(next, at)
    while j >= 0:
      caps[p.slots[i]] = s[at ..< j]
      if go(i + 1, j + next.len, caps): return true
      j = s.find(next, j + 1)
    false
  go(0, p.lits[0].len, caps)

proc trFill(to: string, caps: openArray[string]): string =
  ## a translation with its $n filled in (and $$ as $)
  var i = 0
  while i < to.len:
    if to[i] == '$' and i + 1 < to.len and to[i + 1] == '$':
      result.add '$'
      i += 2
    elif to[i] == '$' and i + 1 < to.len and to[i + 1] in {'1' .. '9'}:
      let k = ord(to[i + 1]) - ord('0')
      if k < caps.len: result.add caps[k]
      i += 2
    else:
      result.add to[i]
      inc i

proc trPart(c: string): string =
  ## a part a pattern found, translated when the catalogue has it as it is or without the spaces around it (" here"
  ## as "here", the spaces kept: a piece ned adds after another text); else as it is
  if c.len == 0: return c
  let e = trExact.getOrDefault(c)
  if e.len > 0: return trUnescape(e)
  var a = 0
  var b = c.high
  while a <= b and c[a] == ' ': inc a
  while b >= a and c[b] == ' ': dec b
  if a > b or (a == 0 and b == c.high): return c
  let t = trExact.getOrDefault(c[a .. b])
  if t.len > 0: c[0 ..< a] & trUnescape(t) & c[b + 1 .. ^1] else: c

proc trPatterns(s: string): (bool, string) =
  ## a text found among the entries with parts: (found, its translation)
  var caps: seq[string]
  proc tryList(l: seq[int], caps: var seq[string]): (bool, string) =
    ## the patterns of one list, the first that matches; each part found is translated too when the catalogue has
    ## it (a word ned chose: "Wrap: $1" with "on")
    for k in l:
      if trMatch(trPats[k], s, caps):
        for c in caps.mitems: c = trPart(c)
        return (true, trFill(trPats[k].to, caps))
  for n in countdown(min(TrHead, s.len), 1):
    let l = trByHead.getOrDefault(s[0 ..< n])
    if l.len > 0:
      let r = tryList(l, caps)
      if r[0]: return r
  for n in countdown(min(TrHead, s.len), 1):
    let l = trByTail.getOrDefault(s[s.len - n .. ^1])
    if l.len > 0:
      let r = tryList(l, caps)
      if r[0]: return r
  tryList(trLoose, caps)

proc trNote(s: string) =
  ## (NED_I18N_RECORD=FILE: each text that came to tr written to FILE once, a JSON string per line — for
  ## tests/i18n/untranslated.py, which finds those the translators' template does not have)
  if trRecording < 0:
    trRecording = 0
    let p = getEnv("NED_I18N_RECORD")
    if p.len > 0 and open(trRecord, p, fmAppend): trRecording = 1
  if trRecording == 1 and s notin trSeen:
    trSeen[s] = true
    trRecord.writeLine($(%s))
    trRecord.flushFile()

proc trIcon(s: string, head: bool): int =
  ## the bytes of a sign before the text (`head`) or after it, with the space between — a word of at most 4 bytes
  ## with no letter or digit: "▶ running", "agent ✓" — so that the words are looked up without it; 0 when none
  const Text = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '$', '(', ')', '[', ']', '"', '\'', '<', '>', '.', ',', ':', '/'}
  let sp = if head: s.find(' ') else: s.rfind(' ')
  if sp < 1 or sp >= s.high: return 0
  let (a, b) = if head: (0, sp - 1) else: (sp + 1, s.high)
  if b - a + 1 > 4: return 0
  for i in a .. b:
    if s[i] in Text: return 0
  if head: sp + 1 else: s.len - sp

proc trLookup*(s: string): string =
  ## `s` in the language in use (`tr` calls it when one is): its translation, or `s`. Spaces around it stay, and the
  ## text between them is looked up (" File " as "File"); so does a sign before or after it when the whole is not
  ## in the catalogue ("▶ running" as "running")
  if s.len == 0: return s
  if trRecording != 0: trNote(s)
  if s[0] == ' ' or s[^1] == ' ':
    var a = 0
    var b = s.high
    while a <= b and s[a] == ' ': inc a
    while b >= a and s[b] == ' ': dec b
    if a > b: return s
    return s[0 ..< a] & trLookup(s[a .. b]) & s[b + 1 .. ^1]
  if trPseudo:
    if s.startsWith("⟦"): return s
    let h = trIcon(s, true)
    if h > 0: return s[0 ..< h] & trLookup(s[h .. ^1])
    let t = trIcon(s, false)
    if t > 0: return trLookup(s[0 ..< s.len - t]) & s[s.len - t .. ^1]
    for c in s:
      if c.isAlphaAscii: return "⟦" & s & "⟧"
    return s
  let e = trExact.getOrDefault(s)
  if e.len > 0: return trUnescape(e)
  if trPats.len == 0 and trIcon(s, true) == 0 and trIcon(s, false) == 0: return s
  if s in trMemo: return trMemo[s]
  var (found, t) = if trPats.len > 0: trPatterns(s) else: (false, "")
  if not found:
    let h = trIcon(s, true)
    let e = trIcon(s, false)
    if h > 0:
      t = s[0 ..< h] & trLookup(s[h .. ^1])
      found = true
    elif e > 0:
      t = trLookup(s[0 ..< s.len - e]) & s[s.len - e .. ^1]
      found = true
  if trMemo.len > 20_000: trMemo.clear()
  result = if found: t else: s
  trMemo[s] = result

template tr*(s: string): string =
  ## `s` as the person reads it: in the language chosen when its catalogue has it, else as it is (English)
  (if trOn: trLookup(s) else: s)

template tx*(s: string): string =
  ## a text to translate where it is shown, not here (a constant's, a table's): `tr` of it there. The template for the
  ## translators (tests/i18n/extract.py) takes it from here
  s

proc trf*(s: string, args: varargs[string, `$`]): string =
  ## a text with parts that change, written with $1 … $9 (trf("Saved $1 files", n)): translated whole, then filled in
  if trRecording != 0 and trOn: trNote(s)
  var caps = @[""]
  for a in args: caps.add a
  let t = if not trOn: s
          elif trPseudo: s
          else: trRaw.getOrDefault(s, s)
  result = trFill(t, caps)
  if trPseudo and result.len > 0 and not result.startsWith("⟦"): result = "⟦" & result & "⟧"

proc trLangOfEnv*(): string =
  ## the language of the system's settings (LC_ALL, LC_MESSAGES, LANG): "ar_OM.UTF-8" → "ar_OM"; "" for C, POSIX
  ## and none
  for v in ["LC_ALL", "LC_MESSAGES", "LANG"]:
    var l = getEnv(v)
    if l.len == 0: continue
    let dot = l.find({'.', '@'})
    if dot >= 0: l = l[0 ..< dot]
    if l in ["C", "POSIX"]: return ""
    return l
  ""

proc trCandidates*(lang: string): seq[string] =
  ## the catalogue names to look for, the most exact first: "pt-BR" → pt_BR, pt
  let l = lang.replace('-', '_')
  if l.len == 0: return
  result.add l
  let u = l.find('_')
  if u > 0: result.add l[0 ..< u]

proc trLoadText*(text: string): string =
  ## a catalogue's entries added to the language in use (a plugin's, or a file's): "" when it was read, else why not
  try:
    let j = parseJson(text)
    if j.kind != JObject: return "not a JSON object of English text → translation"
    for k, v in j:
      if k == "@language" and v.kind == JString: trName = v.getStr
      elif v.kind == JString: trAdd(k, v.getStr)
    trMemo.clear()
    if trCode.len > 0 and not trPseudo: trOn = trExact.len > 0 or trPats.len > 0
    ""
  except CatchableError as e: e.msg

proc trLoad*(lang: string, builtin: openArray[(string, string)], userDir = ""): seq[string] =
  ## the language to use: "" or "en" English; "auto" the system's (trLangOfEnv); "pseudo"; else a code ("ar",
  ## "zh_CN"). Its catalogue is `builtin`'s entry of that name (name, JSON text) with the user's file of that name in
  ## `userDir` over it. What went wrong reading them, each a line ("" none); English when none is found
  trClear()
  trOn = false
  trPseudo = false
  trCode = ""
  var l = lang.strip
  if l == "auto": l = trLangOfEnv()
  if l.len == 0 or l in ["en", "en_US", "en_GB", "C"]: return
  if l in ["pseudo", "qps"]:
    trOn = true
    trPseudo = true
    trCode = "pseudo"
    return
  for c in trCandidates(l):
    var have = userDir.len > 0 and fileExists(userDir / c & ".json")
    for (name, _) in builtin: have = have or name == c
    if not have: continue
    trCode = c
    for (name, text) in builtin:
      if name == c:
        let why = trLoadText(text)
        if why.len > 0: result.add "i18n/" & c & ".json: " & why
    if userDir.len > 0 and fileExists(userDir / c & ".json"):
      let why = try: trLoadText(readFile(userDir / c & ".json")) except IOError as e: e.msg
      if why.len > 0: result.add userDir / c & ".json: " & why
    break

proc trLanguage*(): string =
  ## the language in use: its code ("" English, "pseudo")
  trCode

proc trLanguageName*(): string =
  ## the language in use, named in itself (its catalogue's "@language"; else its code)
  if trName.len > 0: trName else: trCode

proc trCount*(): int =
  ## how many entries the language in use has
  trExact.len + trPats.len
