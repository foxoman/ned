# the GitHub commands, through the gh command line tool: pull requests, issues and Actions runs as menus, and the CI
# status of the current branch shown in the status bar.
proc ghReady(): bool =
  ## can the GitHub commands run: gh must be installed and the folder be a git repository; says what is missing when not
  if not haveExe("gh"):
    warn("This needs the GitHub CLI: " & installHint("gh", "gh") & ", then gh auth login")
    return false
  if gitHome().len == 0:
    info("Not a git repository")
    return false
  true

proc ciRefresh() =
  ## GitHub Actions for this branch → the status bar (looks again while a run is going)
  if not haveExe("gh") or gitBranch.len == 0: return
  let root = gitHome()
  if root.len == 0: return
  let br = gitBranch
  ciDue = false
  discard startJob(jkTool, "gh run list --branch " & quoteShell(br) & " --limit 1 --json status,conclusion 2>/dev/null",
                   root, proc(j: Job) =
    if br != gitBranch: return
    ciBranch = br
    try:
      let a = parseJson(j.output)
      if a.kind != JArray or a.len == 0:
        ciStatus = ""
        return
      let st = a[0]{"status"}.getStr
      let co = a[0]{"conclusion"}.getStr
      ciStatus = if st != "completed": "⟳" elif co == "success": "✓" elif co in ["skipped", "neutral"]: "–" else: "✗"
      if st != "completed":
        ciDue = true
        ciDueAt = getMonoTime() + initDuration(seconds = 30)
    except CatchableError: ciStatus = ""
    needRender = true)

proc ghDone(root, cmd, done: string, then: proc() = nil) =
  ## runs a gh command in the background: `done` said when it worked, else gh's last line as the error
  discard startJob(jkTool, cmd & " 2>&1", root, proc(j: Job) =
    if j.code == 0:
      info(done)
      if then != nil: then()
    else: error("gh: " & (if j.output.strip.len > 0: j.output.strip.splitLines()[^1] else: "exit " & $j.code)))

proc ghReview(root, n, kind: string) =
  ## a review of pull request #n: approve (a comment if you like), request changes or comment (a comment needed)
  let label = case kind
    of "approve": "Approve #" & n & " — a comment (or none):"
    of "request-changes": "Request changes on #" & n & " — what should change:"
    else: "Comment on #" & n & ":"
  askText(label, "", proc(body: string) =
    if body.strip.len == 0 and kind != "approve": return
    ghDone(root, "gh pr review " & n & " --" & kind & (if body.strip.len > 0: " -b " & quoteShell(body.strip) else: ""),
           (case kind
            of "approve": "Approved #" & n
            of "request-changes": "Asked for changes on #" & n
            else: "Commented on #" & n)))

proc ghMerge(root, n, title: string) =
  ## merges pull request #n on GitHub — merge commit, squash or rebase — and deletes its branch there (and here, when
  ## it is not the one checked out)
  openActions("Merge #" & n & "  " & title, @[
    act("Squash and merge", "one commit on the base branch", proc() =
      ghDone(root, "gh pr merge " & n & " --squash --delete-branch", "Merged #" & n & " (squashed)", proc() = refreshGitStatus())),
    act("Merge", "a merge commit", proc() =
      ghDone(root, "gh pr merge " & n & " --merge --delete-branch", "Merged #" & n, proc() = refreshGitStatus())),
    act("Rebase and merge", "its commits, on top of the base branch", proc() =
      ghDone(root, "gh pr merge " & n & " --rebase --delete-branch", "Merged #" & n & " (rebased)", proc() = refreshGitStatus()))])

proc ghPullRequests() =
  ## GitHub › Pull requests: lists the open pull requests (up to 50, with branch, author and draft state); picking one
  ## offers to check it out, show its changes or its checks, read it with its comments, or open it in the browser
  if not ghReady(): return
  let root = gitHome()
  info("Asking GitHub for the pull requests…")
  discard startJob(jkTool, "gh pr list --limit 50 --json number,title,author,headRefName,isDraft 2>&1", root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for pr in jitems(a):
      let n = $pr{"number"}.getInt
      let title = pr{"title"}.getStr
      capture n, title:
        items.add actData("#" & n & "  " & title, pr{"headRefName"}.getStr & " · " & pr{"author"}{"login"}.getStr &
                      (if pr{"isDraft"}.getBool: " · draft" else: ""), proc() =
          openActions(dataText("#" & n & "  " & title), @[
            act("Check it out", "gh pr checkout " & n, proc() =
              discard startJob(jkGit, "gh pr checkout " & n & " 2>&1", root, proc(j2: Job) =
                if j2.code == 0:
                  readBranch()
                  refreshGitStatus()
                  checkDiskChanges()
                  info("On the branch of #" & n)
                else: error("gh: " & j2.output.strip.splitLines()[^1]))),
            act("Its changes", "gh pr diff", proc() =
              toolOutput("PR #" & n, "gh pr diff " & n & " --color=never", root, proc(o: string): string = o,
                         langByName("Diff"))),
            act("Checks (CI)", "gh pr checks", proc() =
              toolOutput("Checks #" & n, "gh pr checks " & n & " 2>&1", root, proc(o: string): string = o,
                         langByName("Text"))),
            act("Read it", "gh pr view", proc() =
              toolOutput("PR #" & n, "gh pr view " & n & " --comments 2>&1", root, proc(o: string): string = o,
                         langByName("Markdown"))),
            act("Approve…", "gh pr review --approve, with a comment if you like", proc() = ghReview(root, n, "approve")),
            act("Request changes…", "gh pr review --request-changes", proc() = ghReview(root, n, "request-changes")),
            act("Comment…", "a review comment on the whole pull request", proc() = ghReview(root, n, "comment")),
            act("Merge…", "merge, squash or rebase it — and delete its branch", proc() = ghMerge(root, n, title)),
            act("Open in the browser", "", proc() =
              discard startJob(jkAux, "gh pr view " & n & " --web", root))]))
    if items.len == 0: info("No open pull requests")
    else: openActions("Pull requests", items))

proc ghNewIssue(root: string) =
  ## a new issue: its title, then its text (gh issue create)
  askText("New issue — its title:", "", proc(title: string) =
    if title.strip.len == 0: return
    askText("What it is about (Enter for nothing more):", "", proc(body: string) =
      discard startJob(jkTool, "gh issue create -t " & quoteShell(title.strip) & " -b " & quoteShell(body.strip) &
                       " 2>&1", root, proc(j: Job) =
        if j.code == 0: info("Opened " & j.output.strip.splitLines()[^1])
        else: error("gh: " & j.output.strip.splitLines()[^1]))))

proc ghIssues() =
  ## GitHub › Issues: lists the open issues (up to 50, with their labels), and New issue…; picking one offers to read
  ## it with its comments, comment on it, close it or open it in the browser
  if not ghReady(): return
  let root = gitHome()
  info("Asking GitHub for the issues…")
  discard startJob(jkTool, "gh issue list --limit 50 --json number,title,labels 2>&1", root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for it in jitems(a):
      let n = $it{"number"}.getInt
      var labels: seq[string]
      for l in jitems(it{"labels"}): labels.add l{"name"}.getStr
      capture n:
        items.add actData("#" & n & "  " & it{"title"}.getStr, labels.join(", "), proc() =
          openActions("#" & n, @[
            act("Read it", "gh issue view", proc() =
              toolOutput("Issue #" & n, "gh issue view " & n & " --comments 2>&1", root, proc(o: string): string = o,
                         langByName("Markdown"))),
            act("Comment…", "", proc() =
              askText("Comment on issue #" & n & ":", "", proc(body: string) =
                if body.strip.len > 0:
                  ghDone(root, "gh issue comment " & n & " -b " & quoteShell(body.strip), "Commented on #" & n))),
            act("Close it", "gh issue close", proc() =
              askConfirm("Close issue #" & n & "? (y)es, (c)lose with a comment, (n)o", proc(c: char) =
                if c == 'y': ghDone(root, "gh issue close " & n, "Closed #" & n)
                elif c == 'c':
                  askText("Close #" & n & " — the comment:", "", proc(body: string) =
                    if body.strip.len > 0:
                      ghDone(root, "gh issue close " & n & " -c " & quoteShell(body.strip), "Closed #" & n)))),
            act("Open in the browser", "", proc() = discard startJob(jkAux, "gh issue view " & n & " --web", root))]))
    items.insert(act("New issue…", "its title, then what it is about", proc() = ghNewIssue(root)), 0)
    openActions("Issues", items))

proc ciLogProblems(log, root: string): int =
  ## a failed run's log → Problems, under "CI": the runner's paths (/home/runner/work/x/x/src/a.nim) taken back to
  ## this checkout, GitHub's annotations (::error file=…,line=…::) as file:line:col: — the number found
  var text = ""
  for raw in log.splitLines:
    var l = raw
    # (gh run view --log-failed: job, step, then the time — before the line itself)
    let parts = l.split('\t', 2)
    if parts.len == 3: l = parts[2]
    if l.len > 29 and l[4] == '-' and l[10] == 'T' and ' ' in l[0 ..< 32]: l = l[l.find(' ') + 1 .. ^1]
    if l.startsWith("::error ") or l.startsWith("::warning ") or l.startsWith("::notice "):
      let e = l.find("::", 2)
      if e > 0:
        var f, line, col = ""
        for kv in l[l.find(' ') + 1 ..< e].split(','):
          let p = kv.split('=', 1)
          if p.len == 2:
            case p[0]
            of "file": f = p[1]
            of "line": line = p[1]
            of "col": col = p[1]
            else: discard
        if f.len > 0 and line.len > 0:
          l = f & ":" & line & ":" & (if col.len > 0: col else: "1") & ": " &
              (if l.startsWith("::error"): "error" elif l.startsWith("::warning"): "warning" else: "note") & ": " &
              l[e + 2 .. ^1]
    let w = l.find("/home/runner/work/")
    if w >= 0:
      # (…/work/<repo>/<repo>/rest: the rest, from this checkout)
      let rest = l[w + 18 .. ^1]
      let a = rest.find('/')
      let b = if a >= 0: rest.find('/', a + 1) else: -1
      if b > 0: l = l[0 ..< w] & rest[b + 1 .. ^1]
    text.add l.strip & "\n"
  problemsFromText("CI", text, root)

proc ghRunAct(root, id, url, title: string, failed: bool): Action =
  ## the menu of one run (a proc of its own: each item keeps its own run) — for a failed one, its failed jobs' log
  ## in Problems and Output, and running them again
  result = proc() =
    var items: seq[(string, string, Action)]
    if failed:
      items.add act("Its errors in Problems", "the failed jobs' log, read for file:line places", proc() =
        info("Asking GitHub for the failed jobs' log…")
        discard startJob(jkTool, "gh run view " & id & " --log-failed 2>&1", root, proc(j: Job) =
          if j.code != 0:
            error("gh: " & j.output.strip.splitLines()[^1])
            return
          let n = ciLogProblems(j.output, root)
          discard openScratch("CI log: " & truncTo(title, 30), j.output, langByName("Text"))
          if n > 0:
            setPanel(pkProblems)
            info($n & " problem" & (if n == 1: "" else: "s") & " from the failed jobs — the whole log in a tab")
          else: info("No file:line place in the failed jobs' log — it is in a tab")))
      items.add act("Run the failed jobs again", "gh run rerun --failed", proc() =
        ghDone(root, "gh run rerun " & id & " --failed", "Running the failed jobs again", proc() = ciRefresh()))
    items.add act("Open in the browser", "", proc() = openInBrowser(url))
    openActions(dataText(truncTo(title, 60)), items)

proc ghRuns() =
  ## GitHub › Actions: lists the latest 15 workflow runs with a mark for their state (running, passed, skipped, failed);
  ## picking one: a failed one's errors in Problems, its failed jobs run again, or the run in the browser. Also
  ## refreshes the status bar's CI mark
  if not ghReady(): return
  let root = gitHome()
  discard startJob(jkTool, "gh run list --limit 15 --json databaseId,displayTitle,status,conclusion,headBranch,url,createdAt,workflowName 2>&1",
                   root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for r in jitems(a):
      let url = r{"url"}.getStr
      let st = r{"status"}.getStr
      let co = r{"conclusion"}.getStr
      let mark = if st != "completed": "⟳" elif co == "success": "✓" elif co in ["skipped", "neutral"]: "–" else: "✗"
      items.add actData(mark & "  " & r{"displayTitle"}.getStr, r{"workflowName"}.getStr & " · " & r{"headBranch"}.getStr,
                        ghRunAct(root, $r{"databaseId"}.getInt, url, r{"displayTitle"}.getStr,
                                 st == "completed" and co notin ["success", "skipped", "neutral"]))
    ciRefresh()
    if items.len == 0: info("No workflow runs")
    else: openActions("GitHub Actions", items))

proc ghMenu() =
  ## the GitHub menu: pull requests, issues, Actions runs, the review comments of this branch's pull request,
  ## creating a pull request, a comment on the current line, and a release
  openActions("GitHub", @[
    act("Pull requests", "check out, see changes and checks, open", proc() = ghPullRequests()),
    act("Issues", "read, open", proc() = ghIssues()),
    act("Actions (CI)", "the latest runs", proc() = ghRuns()),
    act("Review comments", "of this branch's pull request, on their lines — reply, resolve",
        proc() = runCmd("Git: GitHub review comments…")),
    act("Create a pull request", "gh pr create --fill, in the terminal", proc() = runCmd("Git: create a pull request (gh)")),
    act("Comment on this line", "in this branch's pull request", proc() = runCmd("Git: comment on this line in the pull request…")),
    act("Make a release…", "a tag, its notes, files with their SHA-256 (signed with git.releaseKey)",
        proc() = runCmd("Git: make a GitHub release…"))])

proc releaseNotesFor(root, version: string): string =
  ## the release's notes: the section of CHANGELOG.md (else of the README) whose heading names the version — up to
  ## the next heading as big — "" when there is none
  let v = version.strip(trailing = false, chars = {'v', 'V'})
  for f in ["CHANGELOG.md", "CHANGES.md", "README.md"]:
    if not fileExists(root / f): continue
    var lines: seq[string]
    try: lines = readFile(root / f).splitLines
    except CatchableError: continue
    for i, l in lines:
      if not l.startsWith("#") or v notin l: continue
      let level = l.len - l.strip(chars = {'#'}, trailing = false).len
      var e = i + 1
      while e < lines.len:
        let m = lines[e]
        if m.startsWith("#") and m.len - m.strip(chars = {'#'}, trailing = false).len <= level: break
        inc e
      let body = lines[i + 1 ..< e].join("\n").strip
      if body.len > 0: return body

proc ghReleaseRun(root, tag: string, files: seq[string]) =
  ## the release: SHA256SUMS of the files (signed with git.releaseKey, in the namespace <repository>-release — ned's
  ## own is ned-release, what `ned --update` checks), the tag made and pushed when it is new, then gh release create
  ## — a script in the terminal, where ssh-keygen can ask for the key's passphrase and you see each step
  let dir = privDir() / ("release-" & tag.replace("/", "-"))
  var sums = ""
  try:
    removeDir(dir)
    createDir(dir)
    for f in files: sums.add sha256FileHex(f) & "  " & extractFilename(f) & "\n"
    if files.len > 0: writeFile(dir / "SHA256SUMS", sums)
    let notes = releaseNotesFor(root, tag)
    if notes.len > 0: writeFile(dir / "notes.md", notes & "\n")
  except CatchableError as e:
    error("Release: " & e.msg)
    return
  let key = expandTilde(sStr("git.releaseKey"))
  let ns = extractFilename(root) & "-release"
  var s = "set -e\ncd " & quoteShell(root) & "\n"
  s.add "git rev-parse -q --verify " & quoteShell("refs/tags/" & tag) & " >/dev/null || git tag -a " & quoteShell(tag) &
        " -m " & quoteShell(tag) & "\n"
  s.add "git push origin " & quoteShell(tag) & "\n"
  var assets = ""
  for f in files: assets.add " " & quoteShell(f)
  if files.len > 0:
    assets.add " " & quoteShell(dir / "SHA256SUMS")
    if key.len > 0:
      s.add "ssh-keygen -Y sign -f " & quoteShell(key) & " -n " & quoteShell(ns) & " " & quoteShell(dir / "SHA256SUMS") & "\n"
      assets.add " " & quoteShell(dir / "SHA256SUMS.sig")
  s.add "gh release create " & quoteShell(tag) & assets & " --title " & quoteShell(extractFilename(root) & " " & tag) &
        (if fileExists(dir / "notes.md"): " --notes-file " & quoteShell(dir / "notes.md") else: " --generate-notes") & "\n"
  s.add "echo; echo \"Released " & tag & " — gh release view " & tag & " --web\"\n"
  try: writeFile(dir / "release.sh", s)
  except CatchableError as e:
    error("Release: " & e.msg)
    return
  newTerminal()
  let t = curTermObj()
  if t != nil: t.pending = "sh " & quoteShell(dir / "release.sh") & "\r"     # (typed once its shell is ready)

proc cmdGhRelease() =
  ## Git: make a GitHub release… — the tag (the one on this commit, else a new one, from the .nimble version), the
  ## files to attach (build/'s, to change), then what it will do, and with a yes the release (ghReleaseRun)
  if not ghReady(): return
  let root = gitHome()
  var onHead = ""
  let (ok, o, _) = runFilter("git describe --tags --exact-match HEAD 2>/dev/null", "", root, 5000)
  if ok: onHead = o.strip
  var guess = onHead
  if guess.len == 0:
    loadNimbleInfo()
    if nimble.version.len > 0: guess = "v" & nimble.version
  askText("Release — its tag" & (if onHead.len > 0: " (on this commit)" else: " (made on this commit if it is new)") & ":",
          guess, proc(tag0: string) =
    let tag = tag0.strip
    if tag.len == 0 or tag.startsWith("-") or ' ' in tag: return
    var found: seq[string]
    try:
      if dirExists(root / "build"):
        for kind, p in walkDir(root / "build"):
          if kind == pcFile and not p.endsWith(".log") and found.len < 20: found.add relativePath(p, root)
    except CatchableError: discard
    askText("Files to attach (space between them; none: empty):", found.join(" "), proc(list: string) =
      var files: seq[string]
      for w in list.splitWhitespace:
        let p = if w.isAbsolute: w else: root / w
        if not fileExists(p):
          error("Release: no such file " & w)
          return
        files.add p
      let key = sStr("git.releaseKey")
      let signed = files.len > 0 and key.len > 0
      askConfirm("Release " & tag & " on GitHub with " & $files.len & " file" & (if files.len == 1: "" else: "s") &
                 (if files.len > 0: " and their SHA256SUMS" & (if signed: ", signed" else: " (not signed: git.releaseKey)")
                  else: "") & ", notes " & (if releaseNotesFor(root, tag).len > 0: "from the CHANGELOG" else: "from the commits") &
                 " — (y)es, (n)o", proc(c: char) =
        if c == 'y': ghReleaseRun(root, tag, files))))
