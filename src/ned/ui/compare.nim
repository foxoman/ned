# the diff tab's keys, the commands that compare a file with its last commit or with another file, two folders (6.52),
# and the command that opens a Markdown preview
proc diffKey(k: Key): bool =
  ## keys in a diff tab: F7 / Shift+F7 between changes, Enter opens the line, r reverts, a / d accept or reject a
  ## tool's proposed change; typing is ignored
  let b = buf()
  if ideDiffKey(b.id, k): return true                # (a change Claude Code or Gemini CLI proposed: a, d)
  let v = diffViews[b.id]
  v.diffRows()
  let ri = b.primary.head.line
  if k.kind == kFn and k.fn == 7:
    let back = mShift in k.mods
    var k2 = ri
    while true:
      k2 += (if back: -1 else: 1)
      if k2 < 0 or k2 >= v.rows.len:
        info("No more changes")
        return true
      if v.rows[k2].kind != ' ' and (k2 == 0 or v.rows[k2 - 1].kind == ' '): break
    b.setSingle(Pos(line: k2, col: 0))
    return true
  if k.kind == kEnter and k.mods == {}:
    if ri < v.rows.len:
      let r = v.rows[ri]
      let s = if v.src != 0: bufById(v.src) else: nil
      if s != nil:
        var l = r.b
        var q = ri
        while l < 0 and q > 0:
          dec q
          l = v.rows[q].b
        let i = bufs.find(s)
        if i >= 0:
          curBuf = i
          s.centerOn(s.clampPos(Pos(line: max(0, l), col: 0)))
    return true
  if k.kind == kChar and k.mods == {}:
    if k.ch == ord('r'): diffRevertAt(v, ri)
    elif k.ch == ord('n'): return diffKey(Key(kind: kFn, fn: 7))
    elif k.ch == ord('p'): return diffKey(Key(kind: kFn, fn: 7, mods: {mShift}))
    return true
  k.kind in {kBackspace, kDelete, kTab, kPaste}

proc cmdCompareHead() =
  ## the last commit's version on the left, your file on the right — aligned, live
  let b = buf()
  if b.path.len == 0 or not b.inGit:
    info("Compare with last commit works for files in a git repository")
    return
  let id = b.id
  let rel = extractFilename(b.path)
  discard startJob(jkGit, "git --no-pager show " & quoteShell("HEAD:./" & rel), parentDir(b.path), proc(j: Job) =
    let cur = bufById(id)
    if cur == nil: return
    if j.code != 0:
      info("Not in the last commit yet (a new file?)")
      return
    var old = j.output.split('\n')
    if old.len > 0 and old[^1].len == 0: old.setLen(old.len - 1)
    openDiffView(rel, old, "HEAD: " & rel, cur, @[], rel & " (yours)", cur.lang))

proc cmdCompareWithFile() =
  ## this file (right) against another one you pick (left)
  let b = buf()
  if b.isWelcome(): return
  var items: seq[(string, string, Action)]
  let id = b.id
  for rel in projectFiles():
    let path = if rel.isAbsolute: rel else: rootDir / rel
    if path == b.path: continue
    let pp = path
    capture pp:
      items.add act(dataText(relPath(pp)), "", proc() =
        let cur = bufById(id)
        if cur == nil: return
        var other: seq[string]
        let oi = bufIndexByPath(pp)
        if oi >= 0: other = bufs[oi].lines
        else:
          try: other = textLines(readFile(pp))
          except CatchableError as e:
            error(e.msg)
            return
        openDiffView(extractFilename(pp) & " ↔ " & cur.name, other, relPath(pp), cur, @[], cur.name, cur.lang))
    if items.len > 20000: break
  openActions("Compare " & b.name & " with…", items)

var cmpFolders: (string, string)          # the two folders compared last (the command lists them again at once)

proc cmpFolderFiles(root: string): seq[string] =
  ## the files under a folder, as paths from it — not in .git, .hg or .svn, nor through a link to a folder (a loop);
  ## 50 000 at most
  var found: seq[string]
  proc walk(dir, rel: string) =
    ## the files of one folder and of the folders in it
    if found.len >= 50_000: return
    try:
      for kind, p in walkDir(dir, relative = true):
        case kind
        of pcDir:
          if p notin [".git", ".hg", ".svn"]: walk(dir / p, rel & p & "/")
        of pcLinkToDir: discard
        else: found.add rel & p
    except CatchableError: discard
  walk(root, "")
  found.sort()
  found

proc cmpFoldersShow(a, b: string) =
  ## the files that differ between two folders, in a list — those in both whose contents differ (each opens as a
  ## diff: the first folder's on the left), then those only in one; "Other folders…" first, to compare another two
  cmpFolders = (a, b)
  let fa = cmpFolderFiles(a)
  let fb = cmpFolderFiles(b)
  var inB: HashSet[string]
  for p in fb: inB.incl p
  var inA: HashSet[string]
  for p in fa: inA.incl p
  var items: seq[(string, string, Action)]
  items.add act("Other folders…", "", proc() =
    cmpFolders = ("", "")
    runCmd("File: compare two folders…"))
  var differ, onlyA, onlyB = 0
  for p in fa:
    if p notin inB: continue
    var same = false
    try: same = getFileSize(a / p) == getFileSize(b / p) and sameFileContent(a / p, b / p)
    except CatchableError: discard
    if same: continue
    inc differ
    let rel = p
    capture rel:
      items.add act(dataText("± " & rel), "changed", proc() =
        var left: seq[string]
        var right: seq[string]
        try:
          let ta = readFile(a / rel)
          let tb = readFile(b / rel)
          if '\0' in ta or '\0' in tb:
            info(rel & ": binary files that differ")
            return
          left = textLines(ta)
          right = textLines(tb)
        except CatchableError as e:
          error(e.msg)
          return
        let oi = bufIndexByPath(b / rel)
        let live = if oi >= 0: bufs[oi] else: nil
        openDiffView(extractFilename(rel), left, extractFilename(a) & "/" & rel, live, right,
                     extractFilename(b) & "/" & rel, detectLang(rel, "")))
  for p in fa:
    if p notin inB:
      inc onlyA
      let rel = p
      capture rel:
        items.add act(dataText("− " & rel), "only in " & extractFilename(a), proc() = discard openFile(a / rel))
  for p in fb:
    if p notin inA:
      inc onlyB
      let rel = p
      capture rel:
        items.add act(dataText("+ " & rel), "only in " & extractFilename(b), proc() = discard openFile(b / rel))
  if differ + onlyA + onlyB == 0:
    info("The two folders have the same files: " & $fa.len)
    return
  openActions(extractFilename(a) & " ↔ " & extractFilename(b) & ": " & $differ & " changed, " & $onlyA & " only in " &
              extractFilename(a) & ", " & $onlyB & " only in " & extractFilename(b), items)

proc cmdCompareFolders() =
  ## two folders compared, file by file: asks for them (the last two again: listed at once)
  if cmpFolders[0].len > 0 and dirExists(cmpFolders[0]) and dirExists(cmpFolders[1]):
    cmpFoldersShow(cmpFolders[0], cmpFolders[1])
    return
  askPath("First folder:", (if rootDir.len > 0: rootDir & "/" else: getCurrentDir() & "/"), proc(t: string) =
    let a = absolutePath(expandTilde(t.strip)).normalizedPath
    if not dirExists(a):
      error("Not a folder: " & t)
      return
    askPath("Compare " & extractFilename(a) & " with:", parentDir(a) & "/", proc(t2: string) =
      let b = absolutePath(expandTilde(t2.strip)).normalizedPath
      if not dirExists(b) or b == a:
        error("Not another folder: " & t2)
        return
      cmpFoldersShow(a, b)))

proc cmdMarkdownPreview() =
  ## the Markdown file rendered, beside it; it follows your edits — again (or in the preview): the preview closed
  let b = buf()
  if b.mdSrc != 0 and not b.mdNimDocs:
    # (in the preview: it closes, its file in front)
    let src = bufById(b.mdSrc)
    closeBufferAt(curBuf)
    if src != nil:
      let k = bufs.find(src)
      if k >= 0: curBuf = k
    info("Preview closed")
    return
  if b.lang.mode != lmMarkdown:
    info("Open a Markdown file first")
    return
  for i in countdown(bufs.high, 0):
    if bufs[i].mdSrc == b.id and not bufs[i].mdNimDocs:
      closeBufferAt(i)
      if i < curBuf: dec curBuf
      info("Preview closed")
      return
  let pv = openScratch("Preview: " & b.name, "", b.lang)
  pv.mdSrc = b.id
  pv.readOnly = true
  let ci = bufs.find(b)
  if ci < 0: return
  curBuf = ci
  showBeside(b, pv)          # (the file on the left keeps the focus, its preview on the right)
  info("Preview on the right — it follows your edits")
