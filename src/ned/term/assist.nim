# ── help at the shell's prompt (6.52), for a shell that marks its commands (OSC 133): suggestions as you type, above
#    the line — your earlier commands, programs, files and folders, git branches, nimble tasks, nim's commands and the
#    options nim, nimble and ned say they have (6.53) — taken with a tap or
#    Ctrl+Space; a click on the command line moves the shell's cursor there; and the command whose output fills the
#    terminal stays on its top row ──

type TermSug = object
  text: string              # what the word typed becomes (the whole line, for an earlier command)
  kind: string              # what it is: "earlier", "program", "folder", "file", "branch", "task", "git", "nimble",
                            # "nim", "option"
  whole: bool               # it is a whole command line (an earlier one), not the word being typed

var
  termSugs: seq[TermSug]    # the suggestions on screen for the focused terminal, best first
  termSugFor: Term          # … that terminal (nil: none shown at the last frame)
  termSugLine = ""          # … the line typed they are for
  termSugKey = ""           # (what they were worked out for)
  termSugSel = -1           # the one picked with the keys (Ctrl+Space), -1 none
  termSugHidden = ""        # Esc hid them for this line
  termProgs: seq[string]    # the programs on PATH, sorted (read again after a minute)
  termProgsAt: MonoTime
  termHist: seq[string]     # the shell's own history, newest first
  termHistKey = ""          # (its file and when it changed)
  termOpts: Table[string, seq[string]]   # a program's options, from its own --help (6.53: nim, nimble, ned …)
  termOptsAsked: HashSet[string]         # (the programs asked already: once a session)
  termOptsGen = 0                        # (a list came: the suggestions are worked out again)

const
  TermGitCmds = ["add", "bisect", "blame", "branch", "checkout", "cherry-pick", "clean", "clone", "commit", "diff",
                 "fetch", "grep", "init", "log", "merge", "mv", "pull", "push", "rebase", "remote", "reset", "restore",
                 "revert", "rm", "show", "stash", "status", "switch", "tag", "worktree"]
  TermGitBranchCmds = ["checkout", "switch", "merge", "rebase", "branch", "diff", "log", "cherry-pick", "reset", "push",
                       "pull", "show", "worktree"]
  TermNimbleCmds = ["build", "run", "test", "install", "uninstall", "develop", "check", "init", "publish", "search",
                    "list", "tasks", "refresh", "dump", "lock", "path", "c", "cpp", "js", "doc"]
  TermBuiltins = ["cd", "export", "source", "alias", "unset", "exit", "history", "pushd", "popd", "jobs", "fg", "bg"]
  TermNimCmds = ["c", "cpp", "objc", "js", "r", "e", "check", "doc", "jsondoc", "dump", "genDepend", "ctags",
                 "buildIndex", "md2html", "rst2html", "md2tex", "rst2tex", "compile", "nif"]
  TermOptProgs = ["nim", "nimble", "ned", "nedfmt", "nedls", "atlas", "nimsuggest", "testament", "nph", "nimony"]

proc termTyped(t: Term): (bool, string) =
  ## the command line typed so far, up to the cursor — (false, "") unless the terminal is at a marked prompt, live,
  ## with the cursor at the end of what is typed (after it: nothing, or the shell's own suggestion)
  if t.dead or t.altActive or t.view != 0 or not t.integrated or t.cmds.len == 0: return
  let c = t.cmds[^1]
  let g = t.gRow
  if c.ran or c.inputRow < 0 or g < c.inputRow or g - c.inputRow > 4: return
  var s = ""
  for r in c.inputRow .. g:
    let row = t.rowByGlobal(r)
    let a = if r == c.inputRow: c.inputCol else: 0
    let e = if r == g: t.cx else: row.len
    for x in max(0, a) ..< min(e, row.len):
      if row[x].ch != 0: s.addUtf8(int(if row[x].ch < 32: 32'u32 else: row[x].ch))
  let cur = t.rowByGlobal(g)
  for x in t.cx ..< cur.len:
    if cur[x].ch notin [0'u32, 32'u32]: return
  (true, s)

proc termProgList(): seq[string] =
  ## the programs on PATH, by name (read again a minute after the last time)
  if termProgs.len > 0 and msSince(termProgsAt) < 60_000: return termProgs
  var seen: HashSet[string]
  for d in getEnv("PATH").split(PathSep):
    if d.len == 0: continue
    try:
      for kind, p in walkDir(d, relative = true):
        if kind in {pcFile, pcLinkToFile} and p notin seen:
          seen.incl p
          termProgs.add p
    except CatchableError: discard
  termProgs.sort()
  termProgsAt = getMonoTime()
  termProgs

proc termHistory(): seq[string] =
  ## the shell's own history from its file — bash's, zsh's (also with its times), fish's — newest first, each line
  ## once; the last 256 KB of it
  let fam = shellFamily(termShell())
  let home = getHomeDir()
  let path = case fam
    of "bash": getEnv("HISTFILE", home / ".bash_history")
    of "zsh": getEnv("HISTFILE", getEnv("ZDOTDIR", home) / ".zsh_history")
    of "fish": getEnv("XDG_DATA_HOME", home / ".local/share") / "fish" / "fish_history"
    else: ""
  if path.len == 0 or not fileExists(path): return @[]
  let key = try: path & "|" & $getLastModificationTime(path).toUnix except CatchableError: path
  if key == termHistKey: return termHist
  termHistKey = key
  termHist.setLen(0)
  var text = ""
  try:
    var f = open(path)
    defer: f.close()
    let size = f.getFileSize
    if size > 262_144: f.setFilePos(size - 262_144)
    text = f.readAll()
  except CatchableError: return @[]
  var seen: HashSet[string]
  let ls = text.splitLines
  for i in countdown(ls.high, 0):
    var l = ls[i]
    if fam == "fish":
      if not l.startsWith("- cmd: "): continue
      l = l[7 .. ^1].replace("\\n", " ").replace("\\\\", "\\")
    elif fam == "zsh" and l.startsWith(": ") and l.find(';') > 0:
      l = l[l.find(';') + 1 .. ^1]
    l = l.strip
    if l.len == 0 or l.len > 300 or l in seen: continue
    seen.incl l
    termHist.add l
    if termHist.len >= 2000: break
  termHist

proc termGitDir(dir: string): string =
  ## the .git folder of the repository a folder is in ("" none) — a worktree's too (its .git file names it)
  var d = dir
  for _ in 0 .. 30:
    let g = d / ".git"
    if dirExists(g): return g
    if fileExists(g):
      try:
        let s = readFile(g).strip
        if s.startsWith("gitdir:"):
          let p = s[7 .. ^1].strip
          return (if p.isAbsolute: p else: normalizedPath(d / p))
      except CatchableError: discard
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc termBranches(dir: string): seq[string] =
  ## the branches of the repository a folder is in, from its refs (no git run): local ones, then the remotes'
  let g = termGitDir(dir)
  if g.len == 0: return
  var common = g
  try:
    if fileExists(g / "commondir"): common = normalizedPath(g / readFile(g / "commondir").strip)
  except CatchableError: discard
  var seen: HashSet[string]
  var found: seq[string]
  proc add(name: string) =
    ## one branch, once (HEAD of a remote left out)
    if name.len > 0 and not name.endsWith("/HEAD") and name notin seen:
      seen.incl name
      found.add name
  for (sub, cut) in [("refs/heads", 11), ("refs/remotes", 13)]:
    let root = common / sub
    if dirExists(root):
      try:
        for p in walkDirRec(root, relative = true): add(p.replace('\\', '/'))
      except CatchableError: discard
    try:
      if fileExists(common / "packed-refs"):
        for l in lines(common / "packed-refs"):
          let sp = l.find(' ')
          if sp > 0 and l[sp + 1 .. ^1].startsWith(sub & "/"): add(l[sp + 1 + cut .. ^1])
    except CatchableError: discard
  found

proc termNimbleTasks(dir: string): seq[string] =
  ## the tasks of the .nimble file in a folder (`task name, "what it does":`)
  try:
    for kind, p in walkDir(dir):
      if kind != pcFile or not p.endsWith(".nimble"): continue
      for l in lines(p):
        let t = l.strip
        if t.startsWith("task "):
          let comma = t.find(',')
          let n = (if comma > 5: t[5 ..< comma] else: "").strip
          if n.len > 0 and n notin result: result.add n
  except CatchableError: discard

proc termOptsParse(help: string): seq[string] =
  ## the options in a program's --help: each line's first column that starts with -, "-d, --define:SYMBOL" as both,
  ## a value of a few choices ("--opt:none|speed|size") as each choice, any other value as the option and its colon
  for l in help.splitLines:
    let t = l.strip(trailing = false)
    if not t.startsWith("-") or l.len == t.len: continue        # (an option's line is indented)
    var col = t
    let gap = t.find("  ")
    if gap > 0: col = t[0 ..< gap]
    for part in col.split(", "):
      var o = part.strip.split(' ')[0]
      if not o.startsWith("-") or o.len < 2 or o == "--": continue
      let c = o.find({':', '='})
      if c > 0:
        let v = o[c + 1 .. ^1]
        if '|' in v and v.allCharsInSet(IdentChars + {'|'}):
          for x in v.split('|'):
            if x.len > 0 and o[0 .. c] & x notin result: result.add o[0 .. c] & x
          continue
        o = o[0 .. c]
      o = o.strip(leading = false, chars = {',', '.', ']', ')'})
      let br = o.find({'[', '('})
      if br > 0: o = o[0 ..< br]
      if o.len >= 2 and o notin result: result.add o

proc termOptsOf(prog: string): seq[string] =
  ## a program's options (nim's from --fullhelp), read from it once in the background: none the first time
  if prog in termOpts: return termOpts[prog]
  if prog in termOptsAsked or findExe(prog).len == 0: return
  termOptsAsked.incl prog
  let flag = if prog == "nim": "--fullhelp" else: "--help"
  discard startJob(jkAux, quoteShell(prog) & " " & flag & " 2>&1", getHomeDir(), proc(j: Job) =
    termOpts[prog] = termOptsParse(j.output)
    inc termOptsGen
    needRender = true)

proc termSuggestFor(t: Term, line: string): seq[TermSug] =
  ## what to suggest for a command line typed so far: earlier commands it begins, then for the word being typed the
  ## programs (the first word), git's commands and branches, nimble's commands and tasks, the files and folders
  ## (a word with a / or after cd); eight at most
  if line.strip.len == 0: return
  var res: seq[TermSug]
  let local = t.cwd.len > 0                      # (a folder here: not a shell on another machine)
  let dir = if local: t.cwd else: rootDir
  let words = line.splitWhitespace
  let spaceEnd = line[^1] == ' '
  let word = if spaceEnd: "" else: words[^1]
  let argn = if spaceEnd: words.len else: words.len - 1     # (which word is being typed: 0 the command)
  var seen: HashSet[string]
  proc add(text, kind: string, whole = false) =
    ## one suggestion, once, if it adds something to what is typed
    let typed = if whole: line else: word
    if text.len > typed.len and text.startsWith(typed) and text notin seen and res.len < 8:
      seen.incl text
      res.add TermSug(text: text, kind: kind, whole: whole)
  # earlier commands (this terminal's, then the shell's history)
  var hist = 0
  for i in countdown(t.cmds.high, 0):
    if t.cmds[i].ran and hist < 3 and t.cmds[i].text.startsWith(line):
      let before = res.len
      add(t.cmds[i].text, "earlier", true)
      if res.len > before: inc hist
  if local:
    for h in termHistory():
      if hist >= 3: break
      let before = res.len
      add(h, "earlier", true)
      if res.len > before: inc hist
  if argn == 0:
    if word.len == 0 or '/' in word: discard
    else:
      for b in TermBuiltins: add(b, "program")
      if local:
        for p in termProgList():
          if p.startsWith(word): add(p, "program")
          if res.len >= 8: break
    if '/' notin word: return res
  let cmd = if words.len > 0: words[0] else: ""
  let prog = extractFilename(cmd)
  if word.startsWith("-") and prog in TermOptProgs:      # (6.53: the options it says it has)
    for o in termOptsOf(prog): add(o, "option")
    return res
  if prog == "nim" and argn == 1:
    for c in TermNimCmds: add(c, "nim")
    return res
  if cmd == "git" and argn == 1:
    for g in TermGitCmds: add(g, "git")
    return res
  if cmd == "git" and argn >= 2 and words[1] in TermGitBranchCmds and not word.startsWith("-") and local:
    for b in termBranches(dir): add(b, "branch")
  if cmd == "nimble" and argn == 1:
    if local:
      for n in termNimbleTasks(dir): add(n, "task")
    for n in TermNimbleCmds: add(n, "nimble")
    return res
  if not local or (word.len == 0 and cmd != "cd") or word.startsWith("-"): return res
  # files and folders: of the folder the word names so far, from the shell's folder
  let slash = word.rfind('/')
  let head = if slash >= 0: word[0 .. slash] else: ""
  let base = if slash >= 0: word[slash + 1 .. ^1] else: word
  let wd = if head.startsWith("~/"): getHomeDir() / head[2 .. ^1]
           elif head.startsWith("/"): head
           else: dir / head
  var found: seq[(string, bool)]
  try:
    for kind, p in walkDir(wd, relative = true):
      if p.startsWith(base) and (base.startsWith(".") or not p.startsWith(".")):
        found.add (p, kind in {pcDir, pcLinkToDir})
  except CatchableError: discard
  found.sort(proc (a, b: (string, bool)): int = cmp((not a[1], a[0]), (not b[1], b[0])))
  for (p, isDir) in found:
    if cmd == "cd" and not isDir: continue
    add(head & p & (if isDir: "/" else: ""), (if isDir: "folder" else: "file"))
  res

proc termSugInsert(t: Term, s: TermSug) =
  ## a suggestion taken: what it adds to the line typed goes to the shell (a word with a space after it, unless it is
  ## a folder — its files may come next)
  let (ok, line) = t.termTyped()
  if not ok: return
  let typed = if s.whole: line elif line.len > 0 and line[^1] == ' ': "" else: line.splitWhitespace[^1]
  if not s.text.startsWith(typed): return
  var add = s.text[typed.len .. ^1]
  if not s.whole and s.kind != "folder": add.add ' '
  termSugSel = -1
  if add.len > 0: t.termWrite(add)
  needRender = true

proc termSugIcon(kind: string): string =
  ## the mark before a suggestion of a kind
  case kind
  of "earlier": "↺"
  of "folder": "▸"
  of "file": "·"
  of "branch": "⎇"
  of "task", "nimble", "git", "nim": "⚑"
  of "option": "−"
  else: "›"

proc termHelpDraw(ti: int, x0, y0, w, h, gut: int) =
  ## over the terminal drawn at (x0, y0): the command on the top row while its output fills the view
  ## (terminal.stickyCommand), and the focused terminal's suggestions above (or below) its command line
  ## (terminal.suggest), each a place to click
  let t = terms[ti]
  let xs = x0 + gut
  let tw = w - gut - 1
  if cfgTermSticky and t.integrated and h >= 4 and t.navCmd < 0 and not t.altActive:
    let top = t.sb.len - t.view + t.sbDropped
    # (beside the scrollback's badge, on the right of the same row)
    let tw = if t.view > 0: tw - strWidth(" scrollback " & $t.view & "/" & $t.sb.len & " · Shift+PgDn ") - 3 else: tw
    for ci in countdown(t.cmds.high, 0):
      let c = t.cmds[ci]
      if not c.ran or c.outRow > top: continue
      if c.promptRow < top and (c.endRow < 0 or top < c.endRow):
        let bg = blend(theme.bg, theme.accent, 0.18)
        fillRect(xs, y0, tw, 1, theme.fg, bg)
        discard putStr(xs, y0, " $ " & truncTo(c.text, max(4, tw - 4)), theme.fg, bg, {aBold}, xs + tw)
        let tix = ti
        capture tix, ci:
          region(xs, y0, tw, 1, proc() =
            if tix < terms.len: terms[tix].termGoCmd(ci), "Go to this command")
      break
  if t != curTermObj(): return
  termSugFor = nil
  if not cfgTermSuggest or focus != fPanel: return
  let (ok, line) = t.termTyped()
  if not ok or line == termSugHidden:
    if line != termSugHidden: termSugHidden = ""
    return
  termSugHidden = ""
  let key = $cast[int](t) & "|" & line & "|" & t.cwd & "|" & $termOptsGen
  if key != termSugKey:
    termSugKey = key
    termSugs = t.termSuggestFor(line)
    termSugSel = -1
  termSugLine = line
  if termSugs.len == 0: return
  let n = min(termSugs.len, 6)
  var bw = 12
  for i in 0 ..< n: bw = max(bw, strWidth(termSugs[i].text) + strWidth(termSugs[i].kind) + 7)
  bw = min(bw, tw)
  if bw < 12: return
  let y = if t.cy >= n: t.cy - n elif t.cy + 1 + n <= h: t.cy + 1 else: -1
  if y < 0: return
  let word = if line[^1] == ' ': "" else: line.splitWhitespace[^1]
  let bx = clamp(t.cx - strWidth(word) - 2, 0, max(0, tw - bw))
  termSugFor = t
  let bg = theme.codeBg
  for i in 0 ..< n:
    let s = termSugs[i]
    let sel = i == termSugSel
    let rbg = if sel: theme.sel else: bg
    fillRect(xs + bx, y0 + y + i, bw, 1, theme.fg, rbg)
    let label = " " & termSugIcon(s.kind) & " " & truncTo(s.text, max(4, bw - strWidth(s.kind) - 6))
    discard putStr(xs + bx, y0 + y + i, label, theme.fg, rbg, {}, xs + bx + bw)
    discard putStr(xs + bx + bw - strWidth(s.kind) - 1, y0 + y + i, s.kind, theme.dim, rbg, {}, xs + bx + bw)
    let tix = ti
    let si = i
    capture tix, si:
      region(xs + bx, y0 + y + i, bw, 1, proc() =
        focus = fPanel
        if tix < terms.len and si < termSugs.len: terms[tix].termSugInsert(termSugs[si]),
        "Put it in the command line")

proc termSugKeyHit(t: Term, k: Key): bool =
  ## a key while suggestions are shown: Ctrl+Space picks one with the keys (↑/↓, Enter or Tab takes it, Esc hides
  ## them for this line) — true when the key was theirs; any other key goes to the shell
  if termSugFor != t or termSugs.len == 0: return false
  let n = min(termSugs.len, 6)
  if k.kind == kChar and k.ch == ord(' ') and k.mods == {mCtrl}:
    termSugSel = (if termSugSel < 0: 0 else: -1)
    needRender = true
    return true
  if termSugSel < 0: return false
  case k.kind
  of kUp, kDown:
    if k.mods != {}: return false
    termSugSel = (termSugSel + (if k.kind == kUp: n - 1 else: 1)) mod n
    needRender = true
    true
  of kEnter, kTab:
    if k.mods != {}: return false
    t.termSugInsert(termSugs[termSugSel])
    true
  of kEsc:
    termSugSel = -1
    termSugHidden = termSugLine
    needRender = true
    true
  else:
    termSugSel = -1
    false

proc termClickMove(t: Term, x, y: int): bool =
  ## a click on the command line being typed (terminal.clickToMove): the shell's cursor moved there with ← or →, one
  ## for each character between (a click past the end: to the end) — false when the click is not on it
  if not cfgTermClickMove or t.mouseMode != 0 or not t.integrated or t.cmds.len == 0 or t.cmds[^1].ran or
     t.view != 0 or t.altActive or t.dead: return false
  let c = t.cmds[^1]
  if c.inputRow < 0: return false
  let (x0, y0, _, _) = termRect
  let g = t.sb.len - t.view + (y - y0) + t.sbDropped
  var col = max(0, x - x0)                   # (a click in the gutter: the row's start)
  let cur = t.gRow
  if g < c.inputRow or g > cur + 3 or (g == c.inputRow and col < c.inputCol): return false
  # (rows below the cursor's are the command line only while it goes on from the row above)
  var last = cur
  while last < g:
    let prev = t.rowByGlobal(last)
    if prev.len == 0 or prev[^1].ch in [0'u32, 32'u32]: break
    inc last
  if g > last: return false
  let row = t.rowByGlobal(g)
  var e = row.len
  while e > 0 and row[e - 1].ch in [0'u32, 32'u32]: dec e
  if g == c.inputRow: e = max(e, c.inputCol)
  col = min(col, e)
  # the characters between the cursor and there
  proc count(a, b: (int, int)): int =
    ## the characters from place a up to place b (rows and columns)
    var (r, x) = a
    while (r, x) < b:
      let rr = t.rowByGlobal(r)
      if x >= rr.len or x >= t.w:
        inc r
        x = 0
        continue
      if rr[x].ch != 0: inc result
      inc x
  let here = (cur, t.cx)
  let there = (g, col)
  if here == there: return true
  let n = if there > here: count(here, there) else: count(there, here)
  let arrow = (if t.appCursor: "\eO" else: "\e[") & (if there > here: "C" else: "D")
  t.termWrite(arrow.repeat(min(n, 400)))
  true
