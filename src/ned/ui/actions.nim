# ════════════════════════════════════════════════════════════════════════════
#  Nim tooling, nimble/atlas/nimony, git, outline
# ════════════════════════════════════════════════════════════════════════════

var pickActions: seq[Action]
var pickSwatches: seq[int]       # a colour shown before each action's label (the theme editor), -1: none

# one entry for openActions: a label, the grey detail text beside it and what it does
func act(label, detail: string, a: Action): (string, string, Action) = (label, detail, a)

var
  pickFolderDir = ""             # the folder browser's folder (empty: any other picker)
  pickFolderPaths: seq[string]   # the folder behind each of its lines

proc browseFolder(dir: string)
proc openFolder(d: string)
proc gitInitHere(dir = "")
proc gitInitNewProject(dir: string)
proc gitCloneFromLink(link = "")
proc gitIdentityMissing(dir: string): bool
proc gitAskIdentity(dir: string, then: proc() {.closure.} = nil)

var undoPickBuf = -1              # (the undo history's picker: the buffer it shows; -1 for any other picker)

proc openActions(title: string, items: seq[(string, string, proc() {.closure.})], search: seq[string] = @[],
                 data = false) =
  ## a picker of arbitrary actions (label, detail, action); `search`: extra text per item the query may match. The
  ## labels are shown in the language chosen, but with `data` (file names, lines, commits: not ned's words)
  undoPickBuf = -1
  pickActions.setLen(0)
  pickSwatches.setLen(0)
  var its: seq[PickItem]
  for i, (l, d, a) in items:
    # (in the language chosen; the English label is searched too)
    let tl = if data: l else: tr(l)
    its.add PickItem(label: tl, detail: tr(d), idx: i, line: -1, english: (if tl != l: l else: ""),
                     search: (if i < search.len: search[i].toLowerAscii else: ""))
    pickActions.add a
  openPicker(pickAction, title, its)
  pickNear = title == "Quick fixes"
