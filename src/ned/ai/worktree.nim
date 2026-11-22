# An agent in a worktree of its own (6.53; 6.54: from your uncommitted changes too, several kept): AI: agent in a
# worktree starts a conversation with the ACP agent in a git worktree on a new branch, so that it works in the
# background while you edit — your files are not touched. When it is done its changes are committed on that branch,
# to review file by file (each a diff to accept, reject or edit into your files), merge whole, or throw away with
# the worktree. Each worktree stays until it is removed (in .git/ned-worktrees, its first commit beside it in
# NAME.base); the conversation works in the newest one.
# shortcut: one agent works at a time (the agent's one conversation); the others wait to be reviewed

type Wt = object
  path, branch, base, top, name: string

var wtCur: Wt                     # the worktree the conversation works in (path "" none)

proc wtGit(dir, args: string): (bool, string) =
  ## git in a folder: whether it worked, and what it printed (its errors too)
  let (ok, o, e) = runFilter("git " & args, "", dir, 30_000)
  (ok, (o & e).strip)

proc wtCommitAll(dir, msg: string): (bool, string) =
  ## everything in the folder committed (with ned's name when git has none of yours); nothing to commit is fine
  let (_, st) = wtGit(dir, "status --porcelain")
  if st.len == 0: return (true, "")
  discard wtGit(dir, "add -A")
  result = wtGit(dir, "commit -q --no-verify -m " & quoteShell(msg))
  if not result[0] and ("identity" in result[1] or "user.email" in result[1] or "user.name" in result[1]):
    result = wtGit(dir, "-c user.name=ned -c user.email=ned@localhost commit -q --no-verify -m " & quoteShell(msg))

proc wtList(): seq[Wt] =
  ## the agents' worktrees of the project's repository, oldest first
  let (okTop, top) = wtGit(rootDir, "rev-parse --show-toplevel")
  let (okCommon, common0) = wtGit(rootDir, "rev-parse --git-common-dir")
  if not okTop or not okCommon: return
  let store = absolutePath(common0, rootDir).normalizedPath / "ned-worktrees"
  let (ok, said) = wtGit(top, "worktree list --porcelain")
  if not ok: return
  var w: Wt
  for l in (said & "\n").splitLines:
    if l.startsWith("worktree "): w = Wt(path: l[9 .. ^1], top: top)
    elif l.startsWith("branch refs/heads/"): w.branch = l[18 .. ^1]
    elif l.len == 0 and w.path.startsWith(store & "/") and w.branch.startsWith("ned-agent/"):
      w.name = extractFilename(w.path)
      try: w.base = readFile(store / w.name & ".base").strip
      except CatchableError: w.base = wtGit(top, "merge-base HEAD " & quoteShell(w.branch))[1]
      result.add w
      w = Wt()
  result.sort(proc(a, b: Wt): int = cmp(a.name, b.name))

proc wtStart(withMine: bool) =
  ## the new worktree and branch, from your last commit — with your uncommitted changes too when `withMine`
  ## (committed there first, as its base, so that the review shows only the agent's) — and the conversation in it
  let (okTop, top) = wtGit(rootDir, "rev-parse --show-toplevel")
  let (okCommon, common0) = wtGit(rootDir, "rev-parse --git-common-dir")
  let (okHead, head) = wtGit(rootDir, "rev-parse HEAD")
  if not okTop or not okCommon or not okHead:
    info("The agent's worktree needs a git repository with a commit (Git: init, then a first commit)")
    return
  let store = absolutePath(common0, rootDir).normalizedPath / "ned-worktrees"
  let name = "agent-" & now().format("yyyyMMdd-HHmmss")
  let w = Wt(path: store / name, branch: "ned-agent/" & name, base: head, top: top, name: name)
  let (ok, said) = wtGit(top, "worktree add -q -b " & quoteShell(w.branch) & " " & quoteShell(w.path) & " HEAD")
  if not ok:
    error("git worktree add: " & said)
    return
  var base = head
  if withMine:
    # (your changes to tracked files as a patch, your new files copied: then one commit, the agent's starting point)
    let (okD, patch, _) = runFilter("git diff HEAD --binary", "", top, 60_000)
    if okD and patch.len > 0:
      let (okA, _, errA) = runFilter("git apply --binary --whitespace=nowarn -", patch, w.path, 60_000)
      if not okA: error("Your changes did not apply in the worktree: " & errA.strip)
    let (_, others, _) = runFilter("git ls-files --others --exclude-standard", "", top, 30_000)
    for rel in others.splitLines:
      if rel.len == 0: continue
      try:
        createDir(parentDir(w.path / rel))
        copyFile(top / rel, w.path / rel)
      except CatchableError: discard
    let (okC, saidC) = wtCommitAll(w.path, "Your uncommitted changes (ned)")
    if not okC: error("git commit in the agent's worktree: " & saidC)
    base = wtGit(w.path, "rev-parse HEAD")[1]
  try: writeFile(store / name & ".base", base & "\n")
  except CatchableError: discard
  wtCur = Wt(path: w.path, branch: w.branch, base: base, top: top, name: name)
  acpNewChat()
  acpWorkDir = w.path / relativePath(rootDir, top)      # (the project's own folder in it, when it is a part of the repository)
  if relativePath(rootDir, top) in [".", ""]: acpWorkDir = w.path
  showSide(svAssistant)
  acpNotice("This conversation works in a worktree of its own, on the branch " & w.branch & ", from your last " &
            "commit" & (if withMine: " and your uncommitted changes" else: "") & ": your files are not touched while " &
            "it works. When it is done: AI: review the agent's branch.")
  needRender = true

proc cmdWorktreeChat() =
  ## AI: agent in a worktree — a new conversation with the agent, in a new worktree of the project's repository; with
  ## changes not committed yet, whether it starts from them too
  if not acpOn():
    info("Choose an agent first (AI: choose agent…): the worktree is for an ACP agent")
    return
  if acp != nil and acp.turn:
    info("The agent is still working — wait for its answer, or stop it (Esc in the chat), then start another")
    return
  let (ok, st) = wtGit(rootDir, "status --porcelain")
  if ok and st.len > 0:
    openMenu(@[mi("The agent's worktree starts from:", "", disabled = true),
               mi("  your last commit and your uncommitted changes", "", proc() = wtStart(true)),
               mi("  your last commit only", "", proc() = wtStart(false))], scrW div 4, 3)
  else: wtStart(false)

proc wtTurnEnded() =
  ## the agent's answer is complete: when it changed something in its worktree, a toast to review it
  if wtCur.path.len == 0 or not dirExists(wtCur.path): return
  let (ok, st) = wtGit(wtCur.path, "status --porcelain")
  if ok and st.len > 0:
    toast("The agent is done in its worktree (" & wtCur.branch & ")", 3, "Review",
          proc() = runCmd("AI: review the agent's branch"), ttl = 60_000)

proc wtReview(w: Wt)

proc wtFile(w: Wt, rel, status: string) =
  ## one file the agent changed: its version beside yours, to take (a), leave (d) or edit first (e); the list again
  ## after
  let mine = w.top / rel
  var theirs = ""
  if status != "D":
    let (ok, t, _) = runFilter("git show " & quoteShell(w.branch & ":" & rel), "", w.top, 30_000)
    if not ok:
      error("git show " & w.branch & ":" & rel & " failed")
      return
    theirs = t
  proposeDiff("the agent (" & w.branch & ")" & (if status == "D": " — it deleted this file" else: ""), mine, theirs,
    proc(accept: bool, text: string) =
      if accept:
        if status == "D":
          let b = ideBufOf(mine)
          if b != nil:
            let i = bufs.find(b)
            if i >= 0: closeBufferAt(i)
          try: removeFile(mine)
          except CatchableError as e: error("Could not delete " & rel & ": " & e.msg)
          info("Deleted " & rel & ", as the agent did")
        else:
          if not dirExists(parentDir(mine)):
            try: createDir(parentDir(mine))
            except CatchableError: discard
          let (msg, isErr) = toolWriteFile(%*{"path": mine, "content": text})
          if isErr: error(msg) else: info("Took the agent's " & rel & " (AI: undo gives yours back)")
      wtReview(w))

proc wtReview(w: Wt) =
  ## one worktree's branch: its changes committed, then each file it changed (± changed, + new, − deleted) to review,
  ## the whole branch to merge, or the worktree and its branch to remove
  if dirExists(w.path):
    let (ok, said) = wtCommitAll(w.path, "The agent's changes (ned)")
    if not ok:
      error("git commit in the agent's worktree: " & said)
      return
  let (ok, list) = wtGit(w.top, "diff --name-status --no-renames " & quoteShell(w.base) & " " & quoteShell(w.branch))
  if not ok:
    error("git diff: " & list)
    return
  var items: seq[(string, string, Action)]
  var n = 0
  for l in list.splitLines:
    let parts = l.split('\t')
    if parts.len < 2: continue
    let (st, rel) = (parts[0][0 .. 0], parts[1])
    let (mark, what) = case st
                       of "A": ("+ ", "new")
                       of "D": ("− ", "deleted")
                       else: ("± ", "changed")
    inc n
    capture st, rel:
      items.add act(dataText(mark & rel), what & " by the agent", proc() = wtFile(w, rel, st))
  items.add act("Merge the whole branch", "git merge " & w.branch, proc() =
    let (ok, said) = wtGit(w.top, "merge --no-ff --no-edit " & quoteShell(w.branch))
    if ok:
      info("Merged " & w.branch)
      checkDiskChanges()
    else: error("git merge " & w.branch & ": " & said))
  items.add act("Remove the worktree and the branch", "what is not taken or merged is lost", proc() =
    if dirExists(w.path):
      let (ok, said) = wtGit(w.top, "worktree remove --force " & quoteShell(w.path))
      if not ok:
        error("git worktree remove: " & said)
        return
    discard wtGit(w.top, "branch -D " & quoteShell(w.branch))
    try: removeFile(parentDir(w.path) / w.name & ".base")
    except CatchableError: discard
    info("Removed the agent's worktree and " & w.branch)
    if acpWorkDir.len > 0 and acpWorkDir.startsWith(w.path): acpNewChat()
    if wtCur.path == w.path: wtCur = Wt())
  openActions("The agent's branch " & w.branch & ": " & $n & " file" & (if n == 1: "" else: "s") & " changed", items)

proc cmdWorktreeReview() =
  ## AI: review the agent's branch — the worktree the conversation works in, or (several kept) the one you pick
  let all = wtList()
  if all.len == 0:
    info("No agent's worktree here (AI: agent in a worktree)")
    return
  if all.len == 1:
    wtReview(all[0])
    return
  var items: seq[(string, string, Action)]
  for i in countdown(all.high, 0):
    let w = all[i]
    let busy = acp != nil and acp.turn and acpWorkDir.startsWith(w.path)
    let what = if busy: "the agent is working in it" elif w.path == wtCur.path: "the conversation's" else: "kept"
    capture w:                                        # (each item its own worktree: a closure in a loop shares it)
      items.add act(dataText(w.branch), what, proc() = wtReview(w))
  openActions("The agents' worktrees", items)
