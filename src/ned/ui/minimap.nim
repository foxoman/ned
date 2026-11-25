# ── the minimap: the file in small beside the editor, with its marks ──

var
  mmStart = 0
  minimapShown = false

proc minimapWidth(w: int): int =
  ## how many columns the minimap gets in an editor `w` columns wide: 0 when it is off or the editor is too narrow; 10
  ## when on (at 40 columns or more), and under "auto" at 100 or more, but not on a small screen or a slow terminal
  case cfgMinimap
  of "off": 0
  of "on": (if w >= 40: 10 else: 0)
  else: (if w >= 100 and not lay.overlay and not slowTerminal(): 10 else: 0)   # (auto: not on a slow terminal)

proc minimapScroll(y: int) =
  ## a click or a drag on the minimap's row `y`: the view goes there (each row is four lines), that line in the middle
  ## of the editor — the cursor stays where it was, as with the wheel and the scroll bar, and the next key that moves
  ## it brings it back into view (#13)
  if mmRect.h <= 0 or bufs.len == 0: return
  let b = buf()
  let line = clamp(mmFirst + (clamp(y, mmRect.y, mmRect.y + mmRect.h - 1) - mmRect.y) * 4, 0, b.lines.high)
  b.topLine = clamp(line - textH div 2, 0, b.lines.high)
  b.topSub = 0
  b.lastHead = b.primary.head
  b.lastChange = b.changeId
  needRender = true

proc drawMinimap(b: Buffer, x0, y0, w, h: int) =
  ## draws the minimap: every cell is a braille character whose dots show where lines have text (four lines by four
  ## columns of text per cell), the part in view brighter, a row tinted red for a line with an error and in the tag's
  ## colour for a TODO comment, git changes at the left edge and the find box's matches at the right; a long file is
  ## shown as the window that follows the scrolling. A click or drag on it moves the view there, and a right click opens
  ## its menu
  let bg = theme.bg
  fillRect(x0, y0, w, h, theme.minimap, bg)
  let total = b.lines.len
  let cap = h * 4
  var start = 0
  if total > cap:
    let vis = max(1, textH)
    start = clamp(b.topLine * (total - cap) div max(1, total - vis), 0, total - cap)
  mmStart = start
  let vpA = b.topLine
  let vpB = b.topLine + textH
  let dsRef = diagsShared(b.path)
  # the problem list of the buffer being drawn
  template ds: untyped = dsRef[]
  var diagLines: HashSet[int]
  for d in ds:
    if d.sev <= 2: diagLines.incl d.line
  # TODO / NOTE comments in their tag's colour (errors win)
  var todoLines: Table[int, Rgb]
  if cfgTodoHl and todoTags.len > 0:
    for it in todoForBuf(b): todoLines[it.line] = todoColor(min(it.tag, todoTags.high), bg)
  # (6.32) what the find box finds, at the right edge; git's changes at the left
  var findQ = ""
  if promptKind in {pFind, pReplaceFind, pVimSearch} or replaceActive:
    findQ = if replaceActive: replaceQuery else: promptText
  let gitOn = cfgGitGutter and b.git.len > 0
  for row in 0 ..< h:
    let l0 = start + row * 4
    if l0 >= total: break
    let inView = l0 + 3 >= vpA and l0 < vpB
    let rbg = if inView: blend(bg, theme.fg, 0.10) else: bg
    var hasErr = false
    var tagCol = NoColor
    for dy in 0 .. 3:
      if l0 + dy in todoLines and tagCol == NoColor: tagCol = todoLines[l0 + dy]
    for cx in 0 ..< w:
      var bits = 0
      for dy in 0 .. 3:
        let l = l0 + dy
        if l >= total: break
        if l in diagLines: hasErr = true
        let s = b.lines[l]
        for dx in 0 .. 1:
          let c0 = (cx * 2 + dx) * 4
          var on = false
          for k in c0 ..< min(s.len, c0 + 4):
            if s[k] notin {' ', '\t'}:
              on = true
              break
          if on:
            bits = bits or (if dx == 0: [0x01, 0x02, 0x04, 0x40][dy] else: [0x08, 0x10, 0x20, 0x80][dy])
      setCell(x0 + cx, y0 + row, Cell(ch: uint32(0x2800 + bits), fg: (if hasErr: theme.err elif tagCol != NoColor: tagCol
                                                                      else: theme.minimap), bg: rbg))
    if gitOn:
      var g = 0
      for dy in 0 .. 3:
        let l = l0 + dy
        if l < b.git.len and b.git[l] > 0 and (g == 0 or b.git[l] == 3): g = int(b.git[l])
      if g > 0:
        setCell(x0, y0 + row, Cell(ch: (if g == 3: 0x2581'u32 else: 0x258E'u32),
                                   fg: (case g
                                        of 1: theme.gitAdd
                                        of 2: theme.gitMod
                                        else: theme.gitDel), bg: rbg))
    if findQ.len > 0 and w >= 3:
      var hit = false
      for dy in 0 .. 3:
        let l = l0 + dy
        if l < total and findSpans(b.lines[l], findQ, findCase, findWord, findRegex).len > 0:
          hit = true
          break
      if hit: setCell(x0 + w - 1, y0 + row, Cell(ch: 0x2590'u32, fg: theme.matchCur, bg: rbg))
  mmRect = (x0, y0, w, h)
  mmFirst = mmStart
  region(x0, y0, w, h, proc() = minimapScroll(mouseY), "Minimap", proc() = ctxOpen(minimapMenu()))
