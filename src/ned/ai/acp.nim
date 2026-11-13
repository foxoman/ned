# ── ACP, the Agent Client Protocol: an agent that is a program of its own — Claude Agent, Codex, Gemini CLI … — works
#    in the AI dock in place of ned's own assistant (ai.agentServer, one of ai.agentServers). ned starts it, speaks
#    JSON-RPC with it over its standard input and output, shows what it writes, thinks, plans and does, asks you before
#    what it wants to do, and lends it the open files (with their unsaved edits) and commands run in the project.
#    Version 1 of the protocol; version 2 (a draft) when the agent asks for it or the setting says so ──

type
  AcpCb = proc(res, err: JsonNode) {.closure.}   # an answer: its result, or its error (nil when there is none)
  AcpPerm = object                 # the agent waits for you to allow something
    rpcId: JsonNode                # (its request: answered with the option you chose)
    callId: string
    options: seq[(string, string, string)]   # id, name, kind: allow_once, allow_always, reject_once, reject_always
  AcpTerm = ref object             # a command the agent runs through ned (terminal/create)
    id, callId: string
    job: Job
    limit: int                     # the most of its output it wants back, in bytes
    waiters: seq[JsonNode]         # terminal/wait_for_exit requests, answered when it ends
    shown: int                     # how much of its output the chat shows already
  AcpAgent = ref object
    name, title, version: string   # its key in ai.agentServers; what it calls itself
    specKey: string                # the setting it was started from (a change starts it again)
    cmd: seq[string]
    pr: Proc
    inFd, outFd, errFd: cint
    rbuf, wbuf, errPart: string
    wpos: int
    errTail: seq[string]
    nextId: int
    pending: Table[int, (AcpCb, MonoTime, int)]   # callback, when it was sent, how long it may take (0: for ever)
    proto: int                     # the protocol version agreed: 1 or 2 (0 until it answers)
    askedProto: int                # the version ned asked for
    state: string                  # starting · ready · sign in · failed: … · stopped
    caps: JsonNode                 # what it can do (its answer to initialize)
    authMethods: JsonNode          # how one signs in to it
    session: string                # the conversation's id ("" none yet)
    sessionAsked: bool             # session/new sent, not answered yet
    modes: JsonNode                # (v1) its modes: {currentModeId, availableModes}
    config: JsonNode               # its options (mode, model, effort …): a list
    commands: seq[(string, string)]   # its own /commands: name, what it does
    perms: seq[AcpPerm]
    terms: seq[AcpTerm]
    termSeq: int
    v2Terms: Table[string, string] # (v2) a terminal the agent runs itself → the call that shows it
    calls: Table[string, (int, int)]  # a tool call's id → (message, call) in the chat
    msgIds: Table[string, int]     # (v2) a message's id → its place in the chat
    planMsg: int                   # the chat message that shows its plan (-1: none)
    turnStart: int                 # the user's message being answered
    waiting: bool                  # a prompt waits for the agent to start or the session to open
    turn: bool                     # a prompt is being answered
    usedTok, sizeTok: int          # the conversation's size, and the most it may be (usage_update)
    cost: string
    dead, reaped: bool
    startedAt: MonoTime

var
  acp: AcpAgent                    # the agent ned talks to (nil: none started)
  acpWantNewSession = false        # a new chat: the next prompt opens a new session

const
  AcpMaxText = 1_000_000           # the most of one reply the chat keeps (an agent that sends without end)
  AcpCut = "\n\n… (the rest of this reply is not shown: it was over a million characters)"
  AcpPresets = [                   # agents to add with one tap (AI: choose agent…)
    ("claude", "Claude Agent", @["npx", "-y", "@agentclientprotocol/claude-agent-acp"]),
    ("codex", "Codex", @["npx", "-y", "@agentclientprotocol/codex-acp"]),
    ("gemini", "Gemini CLI", @["npx", "-y", "@google/gemini-cli", "--acp"])]

iterator acpPairs(n: JsonNode): (string, JsonNode) =
  ## the key and the value of each entry of an object (none for anything else)
  if n != nil and n.kind == JObject:
    for k, v in n: yield (k, v)

func acpStrs(n: JsonNode): seq[string] =
  ## the strings of a list (none for anything else)
  for x in jitems(n): result.add x.getStr

# the agent named in ai.agentServer ("" for ned's own assistant)
proc acpName(): string = cfgAiAgentServer.strip

# whether the AI dock talks to an agent of its own (ACP) instead of ned's own assistant
proc acpOn(): bool = acpName().len > 0

proc acpSpecOf(name: string): JsonNode =
  ## the agent's entry in ai.agentServers (nil when it has none)
  let all = settingNode("ai.agentServers")
  if all == nil or all.kind != JObject or name.len == 0: return nil
  if all.hasKey(name): return all[name]
  for k, v in all:
    if k.toLowerAscii == name.toLowerAscii: return v
  nil

func acpCmdOf(spec: JsonNode): seq[string] =
  ## the command line of an entry: {"command": "npx", "args": [...]} or {"command": ["npx", "-y", "pkg"]}
  if spec == nil or spec.kind != JObject: return
  let c = spec{"command"}
  if c != nil and c.kind == JString:
    result = @[c.getStr]
    for a in jitems(spec{"args"}): result.add a.getStr
  else:
    for a in jitems(c): result.add a.getStr

# the agent's own name for itself, else its key in the settings
proc acpTitle(): string = (if acp != nil and acp.title.len > 0: acp.title else: acpName())

# who speaks in the chat: the agent's name when one is in use, else the model's
proc acpSpeaker(): string = acpTitle()

# ── the connection: one JSON message per line, each way ──

proc acpFlush(a: AcpAgent) =
  ## writes as much of the waiting output as the agent's pipe takes now (never blocking); a failed write means it died
  if not pipeWrite(a.inFd, a.wbuf, a.wpos): a.dead = true

proc acpSend(a: AcpAgent, j: JsonNode) =
  ## queues one message for the agent, as one line, and writes what it can
  if a.dead: return
  a.wbuf.add $j
  a.wbuf.add '\n'
  a.acpFlush()

proc acpCall(a: AcpAgent, meth: string, params: JsonNode, cb: AcpCb, waitMs = 120_000) =
  ## a request with a new id; `cb` gets its result or error when the answer comes — or an error when the agent stops
  ## or takes longer than `waitMs` (0: it may take as long as it likes, as a prompt does)
  inc a.nextId
  a.pending[a.nextId] = (cb, getMonoTime(), waitMs)
  a.acpSend(%*{"jsonrpc": "2.0", "id": a.nextId, "method": meth, "params": params})

proc acpNotify(a: AcpAgent, meth: string, params: JsonNode) =
  ## a notification: no id, no answer
  a.acpSend(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc acpReply(a: AcpAgent, id, res: JsonNode) =
  ## answers a request of the agent
  a.acpSend(%*{"jsonrpc": "2.0", "id": id, "result": res})

proc acpReplyErr(a: AcpAgent, id: JsonNode, code: int, msg: string) =
  ## answers a request of the agent with an error
  a.acpSend(%*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}})

func acpErrText(err: JsonNode): string =
  ## what an error says: its message, and its details when it has them
  if err == nil: return ""
  if err.kind == JString: return err.getStr
  result = err{"message"}.getStr
  let d = err{"data"}
  if d != nil:
    let t = if d.kind == JString: d.getStr elif d{"details"} != nil: d{"details"}.getStr
            elif d{"message"} != nil: d{"message"}.getStr else: ""
    if t.len > 0 and t != result: result.add (if result.len > 0: ": " else: "") & t
  if result.len == 0: result = "error " & $err{"code"}.getInt

proc acpNotice(t: string) =
  ## a line of ned's in the chat (the agent's state, a sign-in, an error)
  aiMsgs.add AiMsg(role: 3, text: t)
  inc aiVersion
  needRender = true

# ── starting and stopping the agent ──

proc acpInit(a: AcpAgent, v: int)

proc acpStopAgent(why = "stopped") =
  ## stops the agent: its commands killed, its permission requests dropped, the process asked to end (its group), the
  ## pipes closed; a prompt it was answering ends
  let a = acp
  if a == nil: return
  for t in a.terms:
    if t.job != nil and not t.job.done: killProc(t.job.pr)
  a.terms.setLen(0)
  a.perms.setLen(0)
  if a.pr.pid > 0:
    discard posix.kill(Pid(-a.pr.pid), SIGTERM)
    discard waitProc(a.pr, 300)
  closeFd(a.inFd)
  closeFd(a.outFd)
  closeFd(a.errFd)
  a.dead = true
  a.reaped = true
  a.state = why
  if a.turn or a.waiting:
    a.turn = false
    a.waiting = false
    aiBusy = false
    aiPhase = ""
  acp = nil
  inc aiVersion
  needRender = true

proc acpSpawn(a: AcpAgent, spec: JsonNode): bool =
  ## starts the agent's process with its own environment (ai.agentServers' "env", never on a command line), its pipes
  ## not blocking; false, with the state saying why, when it cannot be started
  if a.cmd.len == 0 or findExe(a.cmd[0]).len == 0:
    a.state = "failed: " & (if a.cmd.len == 0: "no command in ai.agentServers" else: a.cmd[0] & " not found" &
                            (if a.cmd[0] in ["npx", "node", "npm"]: " — install Node.js (pkg install nodejs)" else: ""))
    a.dead = true
    return false
  var saved: seq[(string, string, bool)]
  let env = spec{"env"}
  if env != nil and env.kind == JObject:
    for k, v in env:
      saved.add (k, getEnv(k), existsEnv(k))
      putEnv(k, v.getStr)
  try:
    var p = spawnProc(a.cmd, rootDir, siPipe, erPipe)
    a.pr = p
    a.inFd = p.inFd
    a.outFd = p.outFd
    a.errFd = p.errFd
    a.pr.inFd = -1
    a.pr.outFd = -1
    a.pr.errFd = -1
    setNonBlock(a.inFd); setNonBlock(a.outFd); setNonBlock(a.errFd)
  except CatchableError as e:
    a.state = "failed: " & e.msg
    a.dead = true
  for (k, v, had) in saved:
    if had: putEnv(k, v) else: delEnv(k)
  not a.dead

proc acpStart(proto = 0): AcpAgent =
  ## starts the agent named in ai.agentServer and asks it to begin (initialize), in the version of the protocol its
  ## entry asks for ("protocol": 2), else 1 — or `proto` when the agent asked for the other one
  let name = acpName()
  let spec = acpSpecOf(name)
  let a = AcpAgent(name: name, cmd: acpCmdOf(spec), state: "starting", startedAt: getMonoTime(), inFd: -1, outFd: -1,
                   errFd: -1, planMsg: -1, turnStart: -1, specKey: (if spec == nil: "" else: $spec))
  acp = a
  if spec == nil:
    a.state = "failed: no agent called " & name & " in ai.agentServers"
    a.dead = true
    return a
  if not a.acpSpawn(spec): return a
  let want = if proto > 0: proto else: clamp(spec{"protocol"}.getInt(1), 1, 2)
  a.acpInit(want)
  a

proc acpRestartIn(a: AcpAgent, v: int) =
  ## the agent started again in the other version of the protocol, a message that waited for it still waiting
  let w = a.waiting
  acpStopAgent("restarting")
  let b = acpStart(v)
  if w and not b.dead:
    b.waiting = true
    aiBusy = true
    aiPhase = "starting " & acpTitle() & "…"

proc acpInit(a: AcpAgent, v: int) =
  ## initialize: ned says who it is and what it lends the agent (version 1: the files and the terminal), the agent what
  ## it can do. An agent that wants the other version is started again in it (once)
  a.askedProto = v
  let params = if v == 1:
      %*{"protocolVersion": 1, "clientInfo": {"name": "ned", "title": "ned", "version": Version},
         "clientCapabilities": {"fs": {"readTextFile": true, "writeTextFile": true}, "terminal": true,
                                "auth": {"terminal": true}}}
    else:
      %*{"protocolVersion": 2, "info": {"name": "ned", "title": "ned", "version": Version},
         "capabilities": {"auth": {"terminal": {}}}}
  let onInit = proc(res, err: JsonNode) =
    if acp != a: return
    if err != nil or res == nil:
      if v == 1 and err != nil and err{"code"}.getInt == -32022:
        acpRestartIn(a, 2)                   # (a version 2 agent: started again, speaking 2)
        return
      a.state = "failed: " & (if err != nil: acpErrText(err) else: "no answer to initialize")
      if a.waiting: acpNotice(acpTitle() & " did not start: " & a.state[8 .. ^1])
      a.waiting = false
      aiBusy = false
      aiPhase = ""
      needRender = true
      return
    let got = res{"protocolVersion"}.getInt(0)
    if got != v and got in [1, 2]:
      acpRestartIn(a, got)                   # (it speaks the other version: started again in that one)
      return
    a.proto = (if got in [1, 2]: got else: v)
    let info = if a.proto == 1: res{"agentInfo"} else: res{"info"}
    if info != nil and info.kind == JObject:
      a.title = (if info{"title"}.getStr.len > 0: info{"title"}.getStr else: info{"name"}.getStr)
      a.version = info{"version"}.getStr
    a.caps = (if a.proto == 1: res{"agentCapabilities"} else: res{"capabilities"})
    if a.caps == nil: a.caps = newJObject()
    a.authMethods = res{"authMethods"}
    a.state = "ready"
    inc aiVersion
    needRender = true
    if a.waiting: acpTurn()
  a.acpCall("initialize", params, onInit, 300_000)   # (npx may first download the agent: minutes on a phone)

proc acpEnsure(): AcpAgent =
  ## the agent, started when it is not running — again when its entry in the settings changed since
  let spec = acpSpecOf(acpName())
  let key = if spec == nil: "" else: $spec
  if acp != nil and (acp.name != acpName() or acp.specKey != key or acp.dead):
    if not acp.dead or acp.name != acpName() or acp.specKey != key: acpStopAgent("restarting")
    else: acp = nil
  if acp == nil: discard acpStart()
  acp

# ── the session: one conversation with the agent ──

proc acpMcpServers(a: AcpAgent): JsonNode =
  ## ned's MCP servers (ai.mcpServers), handed to the agent for its own use — unless its entry says "mcpServers": false
  result = newJArray()
  let spec = acpSpecOf(a.name)
  if spec != nil and spec{"mcpServers"} != nil and not spec{"mcpServers"}.getBool(true): return
  let all = settingNode("ai.mcpServers")
  if all == nil or all.kind != JObject: return
  for name, sp in all:
    if sp.kind != JObject or sp{"disabled"}.getBool(false): continue
    let cmd = acpCmdOf(sp)
    if cmd.len == 0: continue
    let exe = findExe(cmd[0])
    var env = newJArray()
    for k, v in acpPairs(sp{"env"}): env.add %*{"name": k, "value": v.getStr}
    var s = %*{"name": name, "command": (if exe.len > 0: exe else: cmd[0]), "args": %cmd[1 .. ^1], "env": env}
    if a.proto == 2: s["type"] = %"stdio"
    result.add s

proc acpSignInHelp(a: AcpAgent, msg: string) =
  ## the agent wants you to sign in: what it said, and each way it offers (an entry of AI: agent… runs it)
  var t = acpTitle() & " needs you to sign in" & (if msg.len > 0: ": " & msg else: ".")
  var n = 0
  for m in jitems(a.authMethods):
    inc n
    t.add "\n  · " & m{"name"}.getStr & (if m{"description"}.getStr.len > 0: " — " & m{"description"}.getStr else: "")
  t.add (if n > 0: "\npalette › AI: agent… › Sign in" else: "\nSign in with the agent's own program, then send again " &
         "(palette › AI: agent… restarts it).")
  acpNotice(t)

proc acpTurnEnd(a: AcpAgent, reason: string, errText = "")

proc acpNewSession(a: AcpAgent, then: proc() {.closure.}) =
  ## session/new in the project's folder, with ned's MCP servers; its modes, options and commands are kept. An agent
  ## that wants you to sign in first says so in the chat
  if a.sessionAsked: return
  a.sessionAsked = true
  let onNew = proc(res, err: JsonNode) =
    a.sessionAsked = false
    if acp != a: return
    if err != nil or res == nil or res{"sessionId"}.getStr.len == 0:
      if err != nil and err{"code"}.getInt == -32000:
        a.state = "sign in"
        a.acpSignInHelp(acpErrText(err))
      else:
        acpNotice(acpTitle() & " could not start a conversation: " & (if err != nil: acpErrText(err) else: "no answer"))
      a.waiting = false
      aiBusy = false
      aiPhase = ""
      inc aiVersion
      return
    a.session = res{"sessionId"}.getStr
    a.modes = res{"modes"}
    a.config = res{"configOptions"}
    a.commands.setLen(0)
    for c in jitems(res{"availableCommands"}):
      if c{"name"}.getStr.len > 0: a.commands.add (c{"name"}.getStr, c{"description"}.getStr)
    if a.state == "sign in": a.state = "ready"
    inc aiVersion
    then()
  a.acpCall("session/new", %*{"cwd": rootDir, "mcpServers": a.acpMcpServers()}, onNew, 300_000)

# ── what goes with your message ──

proc acpContext(): string =
  ## what ned tells the agent about the editor with your message (ai.includeFile): the selected lines, else which file
  ## is open and where the cursor is — the agent reads the file itself (through ned: with your unsaved edits)
  let b = buf()
  if b.isWelcome() or b.lines.len == 0 or b.path.len == 0: return ""
  let name = relPath(b.path)
  if aiSecretFile(b.path): return ""
  let (s, e) = b.primary.range
  if s != e:
    return "<selection file=\"" & name & "\" lines=\"" & $(s.line + 1) & "-" & $(e.line + 1) & "\">\n" &
           b.getText(s, e) & "\n</selection>\n\n"
  "(In the editor: " & name & ", line " & $(b.primary.head.line + 1) & ".)\n\n"

proc acpPromptBlocks(a: AcpAgent, m: AiMsg): JsonNode =
  ## your message for the agent: its text, a link to the file it was sent from, and its pictures when the agent takes
  ## pictures
  result = %*[{"type": "text", "text": m.text}]
  if m.file.len > 0 and fileExists(m.file):
    result.add %*{"type": "resource_link", "uri": uriFromPath(m.file), "name": relPath(m.file)}
  let pc = if a.proto == 1: a.caps{"promptCapabilities"} else: a.caps{"session"}{"prompt"}
  let pics = pc != nil and pc{"image"} != nil and (pc{"image"}.kind == JObject or pc{"image"}.getBool(false))
  if pics:
    for p in m.pics:
      let d = aiPicData(p)
      if d.len > 0: result.add %*{"type": "image", "mimeType": aiPicMime(p), "data": d}

proc acpPromptNow(a: AcpAgent) =
  ## sends your last message as a prompt (session/prompt). The answer comes as updates; the turn ends with the
  ## prompt's answer (version 1) or when the agent says it is idle (version 2)
  var ui = aiMsgs.high
  while ui >= 0 and aiMsgs[ui].role != 0: dec ui
  if ui < 0:
    a.waiting = false
    aiBusy = false
    return
  a.waiting = false
  a.turn = true
  a.turnStart = ui
  a.planMsg = -1
  aiBusy = true
  aiPhase = "thinking…"
  aiReqStart = getMonoTime()
  aiMsgs.add AiMsg(role: 1)
  inc aiVersion
  needRender = true
  let onAnswer = proc(res, err: JsonNode) =
    if acp != a or not a.turn: return
    if err != nil:
      if err{"code"}.getInt == -32000:
        a.state = "sign in"
        a.acpTurnEnd("error")
        a.acpSignInHelp(acpErrText(err))
      else: a.acpTurnEnd("error", acpErrText(err))
    elif a.proto == 1: a.acpTurnEnd(res{"stopReason"}.getStr("end_turn"))
  a.acpCall("session/prompt", %*{"sessionId": a.session, "prompt": a.acpPromptBlocks(aiMsgs[ui])}, onAnswer, 0)

proc acpTurn() =
  ## your message goes to the agent (in place of ned's own request): the agent started, a session opened when there
  ## is none, then the prompt — each step waiting for the one before
  let a = acpEnsure()
  aiBusy = true
  inc aiVersion
  needRender = true
  if a == nil or a.dead:
    aiBusy = false
    aiPhase = ""
    acpNotice(acpTitle() & ": " & (if a != nil: a.state else: "not started") & " — palette › AI: agent…")
    return
  if acpWantNewSession:
    acpWantNewSession = false
    a.session = ""
  if a.state == "starting":
    a.waiting = true
    aiPhase = "starting " & acpTitle() & "…"
    return
  if a.session.len == 0:
    a.waiting = true
    aiPhase = "opening a conversation with " & acpTitle() & "…"
    a.acpNewSession(proc() = a.acpPromptNow())
    return
  a.acpPromptNow()

proc acpPermsCancel(a: AcpAgent) =
  ## every permission request still open answered "cancelled", its call marked as not allowed
  for p in a.perms:
    a.acpReply(p.rpcId, %*{"outcome": {"outcome": "cancelled"}})
    if p.callId in a.calls:
      let (mi, ci) = a.calls[p.callId]
      if mi < aiMsgs.len and ci < aiMsgs[mi].calls.len and aiMsgs[mi].calls[ci].state == 0:
        aiMsgs[mi].calls[ci].state = 3
  a.perms.setLen(0)

proc acpTurnEnd(a: AcpAgent, reason: string, errText = "") =
  ## the agent's answer is complete: why it stopped said when it is not the usual end, open permission requests
  ## dropped, an empty reply taken away, the chat saved
  if not a.turn and not a.waiting: return
  a.turn = false
  a.waiting = false
  a.acpPermsCancel()
  aiBusy = false
  aiPhase = ""
  # (replies left empty — the agent planned or acted before it wrote — taken away; the turn's ids are done with)
  var i = aiMsgs.high
  while i > a.turnStart and i >= 0:
    let m = aiMsgs[i]
    if m.role == 1 and m.text.len == 0 and m.calls.len == 0 and m.think.len == 0 and i != a.planMsg:
      aiMsgs.delete(i)
      if a.planMsg > i: dec a.planMsg
    dec i
  a.calls.clear()
  a.msgIds.clear()
  case reason
  of "end_turn", "": discard
  of "cancelled": acpNotice("Stopped.")
  of "max_tokens": acpNotice(acpTitle() & " stopped: its reply reached the most it may write.")
  of "max_turn_requests": acpNotice(acpTitle() & " stopped: it reached the most steps it may take in one answer.")
  of "refusal": acpNotice(acpTitle() & " declined to go on.")
  of "error":
    if errText.len > 0: acpNotice(acpTitle() & ": " & errText)
  else: acpNotice(acpTitle() & " stopped (" & reason & ").")
  saveChat()
  inc aiVersion
  needRender = true

# ── what the agent sends while it works ──

func acpBlockText(c: JsonNode): string =
  ## the text of a content block: its text; a link or a resource by its name or address; a picture or a sound as a note
  if c == nil or c.kind != JObject: return ""
  case c{"type"}.getStr
  of "text": c{"text"}.getStr
  of "resource_link": "[" & (if c{"title"}.getStr.len > 0: c{"title"}.getStr else: c{"name"}.getStr) & "](" &
                      c{"uri"}.getStr & ")"
  of "resource":
    let r = c{"resource"}
    if r{"text"}.getStr.len > 0: r{"text"}.getStr else: r{"uri"}.getStr
  of "image", "audio": "[" & c{"type"}.getStr & "]"
  else: ""

proc acpAsst(a: AcpAgent, kind: int): int =
  ## the chat message the agent's next words (kind 0), thoughts (1) or action (2) go into: the current reply of this
  ## turn — but words after its actions, and thoughts after anything, begin a new one so that the chat keeps their
  ## order, and the plan keeps a message of its own
  let mi = aiMsgs.high
  if mi >= 0 and mi > a.turnStart and aiMsgs[mi].role == 1 and mi != a.planMsg:
    case kind
    of 0:
      if aiMsgs[mi].calls.len == 0: return mi
    of 1:
      if aiMsgs[mi].text.len == 0 and aiMsgs[mi].calls.len == 0: return mi
    else: return mi
  aiMsgs.add AiMsg(role: 1)
  aiMsgs.high

proc acpMsgFor(a: AcpAgent, u: JsonNode, kind: int): int =
  ## the message an update belongs to: (version 2) the one with its id, kept from the first time; else acpAsst's
  let id = u{"messageId"}.getStr
  if id.len > 0 and id in a.msgIds and a.msgIds[id] < aiMsgs.len: return a.msgIds[id]
  result = a.acpAsst(kind)
  if id.len > 0: a.msgIds[id] = result

func acpStateOf(status: string): (int, bool) =
  ## a tool call's status as the chat's: (its state, whether it failed)
  case status
  of "completed": (2, false)
  of "failed": (2, true)
  else: (1, false)

proc acpCallAt(a: AcpAgent, id: string): (int, int) =
  ## the place in the chat of the tool call with this id — a new call in the current reply when there is none
  if id in a.calls:
    let (mi, ci) = a.calls[id]
    if mi < aiMsgs.len and ci < aiMsgs[mi].calls.len and aiMsgs[mi].calls[ci].id == id: return (mi, ci)
  let mi = a.acpAsst(2)
  aiMsgs[mi].calls.add AiCall(id: id, name: "acp:other", state: 1)
  result = (mi, aiMsgs[mi].calls.high)
  a.calls[id] = result

proc acpDiffOf(item: JsonNode): (string, string) =
  ## a diff the agent shows: (as a unified diff, the path) — version 1 gives the old and the new text, version 2 a
  ## patch, or only what changed
  let p = item{"path"}.getStr
  if p.len > 0:
    let rel = relPath(p)
    let old = item{"oldText"}.getStr
    let d = unifiedDiff(textLines(old), textLines(item{"newText"}.getStr),
                        (if item{"oldText"} == nil or item{"oldText"}.kind == JNull: "/dev/null" else: "a/" & rel), "b/" & rel)
    return ((if d.len > 0: d else: "(no change)"), p)
  if item{"patch"} != nil and item{"patch"}{"text"}.getStr.len > 0:
    var first = ""
    for ch in jitems(item{"changes"}):
      if first.len == 0: first = ch{"path"}.getStr
    return (item{"patch"}{"text"}.getStr, first)
  var t = ""
  var first = ""
  for ch in jitems(item{"changes"}):
    let cp = ch{"path"}.getStr(ch{"newPath"}.getStr)
    if first.len == 0: first = cp
    t.add ch{"operation"}.getStr & " " & relPath(cp) & "\n"
  (t, first)

proc acpContent(a: AcpAgent, mi, ci: int, item: JsonNode) =
  ## one piece of a tool call's content into its chat line: text added to its result, a diff kept as its diff, a
  ## terminal linked so that its output shows as it comes
  template c: untyped = aiMsgs[mi].calls[ci]
  case item{"type"}.getStr
  of "content":
    let t = acpBlockText(item{"content"})
    if t.len > 0: c.result.add (if c.result.len > 0 and not c.result.endsWith("\n"): "\n" else: "") & t
  of "diff":
    let (d, p) = acpDiffOf(item)
    c.diff = (if c.diff.len > 0 and p.len > 0 and p notin c.diff: c.diff & "\n" & d else: d)
    if c.loc.len == 0: c.loc = p
  of "terminal":
    let tid = item{"terminalId"}.getStr
    for t in a.terms:
      if t.id == tid: t.callId = c.id
    if a.proto == 2: a.v2Terms[tid] = c.id
  else: discard

proc acpApplyCall(a: AcpAgent, mi, ci: int, u: JsonNode) =
  ## a tool call's fields from the agent into its chat line: title, kind, status, where it works, what it was given,
  ## its content (which replaces what it had: an update says it whole)
  template c: untyped = aiMsgs[mi].calls[ci]
  if u{"title"} != nil and u{"title"}.kind == JString: c.args = u{"title"}.getStr
  if u{"kind"} != nil and u{"kind"}.kind == JString: c.name = "acp:" & u{"kind"}.getStr
  if u{"status"} != nil and u{"status"}.kind == JString and c.state != 0:
    (c.state, c.isError) = acpStateOf(u{"status"}.getStr)
  if u{"rawInput"} != nil and u{"rawInput"}.kind != JNull: c.raw = $u{"rawInput"}
  for l in jitems(u{"locations"}):
    if l{"path"}.getStr.len > 0:
      c.loc = l{"path"}.getStr & (if l{"line"} != nil and l{"line"}.kind == JInt: ":" & $l{"line"}.getInt else: "")
      break
  if u{"content"} != nil and u{"content"}.kind == JArray:
    c.result = ""
    for item in u{"content"}: a.acpContent(mi, ci, item)
  if u{"rawOutput"} != nil and u{"rawOutput"}.kind != JNull and c.result.len == 0:
    let ro = u{"rawOutput"}
    c.result = (if ro.kind == JString: ro.getStr else: truncTo($ro, 4000))
  if c.state == 1 and u{"status"}.getStr == "in_progress": aiPhase = truncTo(c.args, 50) & "…"

proc acpPlan(a: AcpAgent, entries: JsonNode) =
  ## the agent's plan as a message of its own, put right as it changes: ✓ done, ▸ under way, ○ to do
  var t = "**Plan**\n"
  for e in jitems(entries):
    let mark = case e{"status"}.getStr
               of "completed": "✓"
               of "in_progress": "▸"
               else: "○"
    t.add "\n- " & mark & " " & e{"content"}.getStr
  if a.planMsg >= 0 and a.planMsg < aiMsgs.len and aiMsgs[a.planMsg].role == 1:
    aiMsgs[a.planMsg].text = t
  else:
    aiMsgs.add AiMsg(role: 1, text: t)
    a.planMsg = aiMsgs.high

proc acpAddCapped(t: var string, piece: string) =
  ## a piece of a reply added, up to a million characters in all (then a note that the rest is not kept)
  if t.len + piece.len <= AcpMaxText:
    t.add piece
  elif t.len < AcpMaxText:
    t.add piece[0 ..< utf8Cut(piece, AcpMaxText - t.len)]
    t.add AcpCut

proc acpUpdate(a: AcpAgent, u: JsonNode) =
  ## one session/update: words, thoughts, tool calls and their content, the plan, its commands, mode and options, the
  ## conversation's size; in version 2 also whole messages and the agent's state (idle ends the turn)
  if u == nil or u.kind != JObject: return
  case u{"sessionUpdate"}.getStr
  of "agent_message_chunk":
    let mi = a.acpMsgFor(u, 0)
    acpAddCapped(aiMsgs[mi].text, acpBlockText(u{"content"}))
    if aiPhase.startsWith("thinking"): aiPhase = "writing…"
  of "agent_message":
    let mi = a.acpMsgFor(u, 0)
    var t = ""
    for c in jitems(u{"content"}): t.add acpBlockText(c)
    aiMsgs[mi].text = t
  of "agent_thought_chunk":
    let mi = a.acpMsgFor(u, 1)
    acpAddCapped(aiMsgs[mi].think, acpBlockText(u{"content"}))
    aiPhase = "thinking…"
  of "agent_thought":
    let mi = a.acpMsgFor(u, 1)
    var t = ""
    for c in jitems(u{"content"}): t.add acpBlockText(c)
    aiMsgs[mi].think = t
  of "tool_call", "tool_call_update":
    let id = u{"toolCallId"}.getStr
    if id.len == 0: return
    let (mi, ci) = a.acpCallAt(id)
    a.acpApplyCall(mi, ci, u)
  of "tool_call_content_chunk":
    let id = u{"toolCallId"}.getStr
    if id.len == 0: return
    let (mi, ci) = a.acpCallAt(id)
    a.acpContent(mi, ci, u{"content"})
  of "terminal_output_chunk":
    let cid = a.v2Terms.getOrDefault(u{"terminalId"}.getStr)
    if cid.len > 0 and cid in a.calls:
      let (mi, ci) = a.calls[cid]
      if mi < aiMsgs.len and ci < aiMsgs[mi].calls.len:
        var d = ""
        try: d = decode(u{"data"}.getStr)
        except CatchableError: discard
        aiMsgs[mi].calls[ci].result.add stripAnsi(d)
        if aiMsgs[mi].calls[ci].result.len > 20000:
          let r = aiMsgs[mi].calls[ci].result
          aiMsgs[mi].calls[ci].result = r[utf8Cut(r, r.len - 16000) .. ^1]
  of "plan": a.acpPlan(u{"entries"})
  of "plan_update": a.acpPlan(u{"plan"}{"entries"})
  of "available_commands_update":
    a.commands.setLen(0)
    for c in jitems(u{"availableCommands"}):
      if c{"name"}.getStr.len > 0: a.commands.add (c{"name"}.getStr, c{"description"}.getStr)
  of "current_mode_update":
    if a.modes != nil and a.modes.kind == JObject: a.modes["currentModeId"] = %u{"currentModeId"}.getStr
  of "config_option_update": a.config = u{"configOptions"}
  of "usage_update":
    a.usedTok = u{"used"}.getInt
    a.sizeTok = u{"size"}.getInt
    let c = u{"cost"}
    if c != nil and c.kind == JObject:
      a.cost = (if c{"currency"}.getStr in ["USD", ""]: "$" & formatFloat(c{"amount"}.getFloat, ffDecimal, 2)
                else: formatFloat(c{"amount"}.getFloat, ffDecimal, 2) & " " & c{"currency"}.getStr)
  of "notice":
    if u{"title"}.getStr.len > 0: acpNotice(acpTitle() & ": " & u{"title"}.getStr)
  of "state_update":
    case u{"state"}.getStr
    of "idle":
      if a.turn:
        let r = u{"stopReason"}.getStr("end_turn")
        a.acpTurnEnd(r, (if r == "error": acpErrText(u{"error"}) else: ""))
    of "running":
      if not aiBusy:
        aiBusy = true
        aiPhase = "working…"
    of "requires_action": aiPhase = "waiting for you"
    else: discard
  else: discard                                # (user_message: ned shows yours; session_info_update …)
  inc aiVersion
  needRender = true

# ── what the agent asks of ned ──

proc acpKindClass(name: string): int =
  ## a call's kind as ned's own tools': 0 reads, 1 changes files, 2 runs something (for ai.autoApprove)
  case name
  of "acp:read", "acp:search", "acp:fetch", "acp:think": 0
  of "acp:edit", "acp:delete", "acp:move": 1
  else: 2

proc acpAutoAllow(c: AiCall): bool =
  ## whether ned allows what the agent asks by itself: never for a path outside the project, else by the kind of call
  ## and ai.autoApprove (reads unless "none", changes with "edits" or "all", anything with "all") or a kind allowed
  ## always in this chat
  let p = c.loc.split(':')[0]
  if p.len > 0:
    let q = absolutePath(expandTilde(p)).normalizedPath
    if q != rootDir and not q.startsWith(rootDir & "/"): return false
  if c.name in aiAlwaysAllow: return true
  case acpKindClass(c.name)
  of 0: cfgAiApprove != "none"
  of 1: cfgAiApprove in ["edits", "all"]
  else: cfgAiApprove == "all"

func acpPick(p: AcpPerm, kinds: openArray[string]): string =
  ## the id of the first of the agent's options of one of these kinds, in the order given ("" when it has none)
  for k in kinds:
    for (id, _, kind) in p.options:
      if kind == k: return id
  ""

proc acpPermission(a: AcpAgent, id, params: JsonNode) =
  ## session/request_permission: the call it is about shown with what it would do and Allow, Always, Deny — or
  ## allowed at once when ai.autoApprove says so
  var u = params{"toolCall"}
  if u == nil: u = params{"subject"}{"toolCall"}
  var cid = if u != nil: u{"toolCallId"}.getStr else: ""
  if cid.len == 0: cid = params{"subject"}{"toolCallId"}.getStr
  if cid.len == 0: cid = "perm-" & $id
  let (mi, ci) = a.acpCallAt(cid)
  if u != nil: a.acpApplyCall(mi, ci, u)
  if params{"title"}.getStr.len > 0 and aiMsgs[mi].calls[ci].args.len == 0: aiMsgs[mi].calls[ci].args = params{"title"}.getStr
  let sc = params{"subject"}{"command"}.getStr
  if sc.len > 0 and aiMsgs[mi].calls[ci].raw.len == 0: aiMsgs[mi].calls[ci].raw = $(%*{"command": sc})
  var p = AcpPerm(rpcId: id, callId: cid)
  for o in jitems(params{"options"}): p.options.add (o{"optionId"}.getStr, o{"name"}.getStr, o{"kind"}.getStr)
  if acpAutoAllow(aiMsgs[mi].calls[ci]):
    let o = p.acpPick(["allow_once", "allow_always"])
    if o.len > 0:
      a.acpReply(id, %*{"outcome": {"outcome": "selected", "optionId": o}})
      return
  a.perms.add p
  aiMsgs[mi].calls[ci].state = 0
  aiPhase = "waiting for approval"
  showSide(svAssistant)
  inc aiVersion
  needRender = true

proc acpWaiting(callId: string): bool =
  ## whether the agent waits for your answer about this call
  if acp == nil: return false
  for p in acp.perms:
    if p.callId == callId: return true
  false

proc acpAnswer(mi, ci: int, allow, always: bool) =
  ## your answer to what the agent asked about a call: the option of that kind sent back (Always: allowed for the rest
  ## of the chat too, here and by the agent), the call marked as running or not allowed
  let a = acp
  if a == nil or mi >= aiMsgs.len or ci >= aiMsgs[mi].calls.len: return
  let cid = aiMsgs[mi].calls[ci].id
  for i, p in a.perms:
    if p.callId != cid: continue
    let o = if allow and always: p.acpPick(["allow_always", "allow_once"])
            elif allow: p.acpPick(["allow_once", "allow_always"])
            else: p.acpPick(["reject_once", "reject_always"])
    if o.len > 0: a.acpReply(p.rpcId, %*{"outcome": {"outcome": "selected", "optionId": o}})
    else: a.acpReply(p.rpcId, %*{"outcome": {"outcome": "cancelled"}})
    a.perms.delete(i)
    if always and allow: aiAlwaysAllow.incl aiMsgs[mi].calls[ci].name
    aiMsgs[mi].calls[ci].state = (if allow: 1 else: 3)
    aiPhase = (if a.perms.len > 0: "waiting for approval" elif allow: truncTo(aiMsgs[mi].calls[ci].args, 50) & "…"
               else: "working…")
    inc aiVersion
    needRender = true
    return

proc acpCallInfo(c: AiCall): (string, bool) =
  ## what the approval card of an agent's call shows: its diff, else the command it runs, else its title and what it
  ## was given; and whether that is a diff
  if c.diff.len > 0: return (c.diff, true)
  var j: JsonNode
  try: j = parseJson(if c.raw.len > 0: c.raw else: "{}")
  except CatchableError: j = newJObject()
  if j.kind == JObject and j{"command"} != nil:
    let cmd = if j{"command"}.kind == JString: j{"command"}.getStr else: acpStrs(j{"command"}).join(" ")
    return ("$ " & cmd & (if j{"cwd"}.getStr.len > 0: "\n  in " & j{"cwd"}.getStr else: ""), false)
  var t = c.args
  if c.loc.len > 0: t.add "\n  " & relPath(c.loc)
  if c.raw.len > 2 and j.kind == JObject and j.len > 0: t.add "\n" & truncTo(j.pretty, 800)
  (t, false)

proc acpReadFile(a: AcpAgent, id, p: JsonNode) =
  ## fs/read_text_file: the file's text from its tab when it is open (your unsaved edits too), else from the disk —
  ## from `line` (1 is the first), `limit` lines; a file of secrets is not given (ai.redactSecrets)
  if p{"path"}.getStr.len == 0:
    a.acpReplyErr(id, -32602, "fs/read_text_file needs a path")
    return
  let path = absolutePath(expandTilde(p{"path"}.getStr)).normalizedPath
  if aiSecretFile(path):
    a.acpReplyErr(id, -32603, AiSecretNote)
    return
  var text = ""
  let bi = bufIndexByPath(path)
  if bi >= 0: text = bufs[bi].allText
  elif fileExists(path):
    try:
      if getFileSize(path) > 16_000_000:
        a.acpReplyErr(id, -32603, "the file is too large (" & $getFileSize(path) & " bytes)")
        return
      text = readFile(path)
    except CatchableError as e:
      a.acpReplyErr(id, -32603, e.msg)
      return
  else:
    a.acpReplyErr(id, -32002, "no such file: " & path)
    return
  let first = p{"line"}.getInt(0)
  let limit = p{"limit"}.getInt(0)
  if first > 1 or limit > 0:
    let ls = text.split('\n')
    let s = clamp(first - 1, 0, ls.len)
    let e = if limit > 0: min(ls.len, s + limit) else: ls.len
    text = ls[s ..< e].join("\n")
  a.acpReply(id, %*{"content": text})

proc acpWriteFile(a: AcpAgent, id, p: JsonNode) =
  ## fs/write_text_file: the file's whole text replaced — in its tab, saved, when it is open, else on the disk — with
  ## what it was kept first for AI: undo and AI: review the assistant's changes
  if p{"path"}.getStr.len == 0 or p{"content"} == nil or p{"content"}.kind != JString:
    a.acpReplyErr(id, -32602, "fs/write_text_file needs a path and the content as text")
    return
  let path = absolutePath(expandTilde(p{"path"}.getStr)).normalizedPath
  if dirExists(path):
    a.acpReplyErr(id, -32602, path & " is a folder")
    return
  let (msg, isErr) = toolWriteFile(%*{"path": path, "content": p{"content"}.getStr})
  if isErr: a.acpReplyErr(id, -32603, msg)
  else: a.acpReply(id, newJObject())

proc acpTermOf(a: AcpAgent, p: JsonNode): AcpTerm =
  ## the command a terminal request is about (nil when ned has no such one)
  let tid = p{"terminalId"}.getStr
  for t in a.terms:
    if t.id == tid: return t
  nil

proc acpTermOutput(t: AcpTerm): (string, bool) =
  ## what the command wrote so far, cut to the end the agent wants (outputByteLimit, at a character's edge), and
  ## whether it was cut
  var o = t.job.output & t.job.partial
  if t.limit > 0 and o.len > t.limit:
    return (o[utf8Cut(o, o.len - t.limit) .. ^1], true)
  (o, false)

proc acpTermCreate(a: AcpAgent, id, p: JsonNode) =
  ## terminal/create: the command run in the background, in the project (or the folder it names), with the variables
  ## it gives; its id goes back at once
  if p{"command"}.getStr.len == 0:
    a.acpReplyErr(id, -32602, "terminal/create needs a command")
    return
  var line = quoteShell(p{"command"}.getStr)
  for x in jitems(p{"args"}): line.add " " & quoteShell(x.getStr)
  var envs = ""
  for e in jitems(p{"env"}):
    if e{"name"}.getStr.len > 0: envs.add quoteShell(e{"name"}.getStr & "=" & e{"value"}.getStr) & " "
  if envs.len > 0: line = "env " & envs & line
  let cwd = if p{"cwd"}.getStr.len > 0: p{"cwd"}.getStr else: rootDir
  let j = startJob(jkTool, line, cwd)
  if j == nil:
    a.acpReplyErr(id, -32603, "could not start " & p{"command"}.getStr)
    return
  inc a.termSeq
  let t = AcpTerm(id: "ned-term-" & $a.termSeq, job: j, limit: p{"outputByteLimit"}.getInt(1_000_000))
  a.terms.add t
  a.acpReply(id, %*{"terminalId": t.id})

proc acpTermExit(t: AcpTerm): JsonNode =
  ## how the command ended, as the protocol says it
  %*{"exitCode": t.job.code, "signal": nil}

proc acpTermRequest(a: AcpAgent, meth: string, id, p: JsonNode) =
  ## terminal/output, terminal/wait_for_exit (answered when it ends), terminal/kill, terminal/release (stopped if it
  ## runs, and forgotten)
  let t = a.acpTermOf(p)
  if t == nil:
    a.acpReplyErr(id, -32002, "no such terminal")
    return
  case meth
  of "terminal/output":
    let (o, cut) = acpTermOutput(t)
    var r = %*{"output": o, "truncated": cut}
    if t.job.done: r["exitStatus"] = acpTermExit(t)
    a.acpReply(id, r)
  of "terminal/wait_for_exit":
    if t.job.done: a.acpReply(id, acpTermExit(t))
    else: t.waiters.add id
  of "terminal/kill":
    if not t.job.done: killProc(t.job.pr)
    a.acpReply(id, newJObject())
  else:                                          # terminal/release
    if not t.job.done: killProc(t.job.pr)
    for i, x in a.terms:
      if x == t:
        a.terms.delete(i)
        break
    a.acpReply(id, newJObject())

proc acpHandle(a: AcpAgent, j: JsonNode) =
  ## one message from the agent: an answer calls its request's callback; its requests (permission, files, terminals)
  ## are answered; session/update is shown; anything else is left alone (a request answered "not supported")
  if j.kind != JObject: return
  if j.hasKey("id") and (j.hasKey("result") or j.hasKey("error")) and not j.hasKey("method"):
    let id = j["id"].getInt(-1)
    if id in a.pending:
      let (cb, _, _) = a.pending[id]
      a.pending.del id
      let e = j{"error"}
      cb(j{"result"}, (if e != nil and e.kind != JNull: e else: nil))
    return
  let meth = j{"method"}.getStr
  let p = j{"params"}
  if j.hasKey("id"):
    let id = j["id"]
    case meth
    of "session/request_permission": a.acpPermission(id, p)
    of "fs/read_text_file": a.acpReadFile(id, p)
    of "fs/write_text_file": a.acpWriteFile(id, p)
    of "terminal/create": a.acpTermCreate(id, p)
    of "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release": a.acpTermRequest(meth, id, p)
    else: a.acpReplyErr(id, -32601, meth & " is not supported by ned")
  elif meth == "session/update":
    # (the conversation's own; one left behind by a new chat is not shown)
    if p != nil and a.session.len > 0 and p{"sessionId"}.getStr in ["", a.session]: a.acpUpdate(p{"update"})

proc acpRead(a: AcpAgent) =
  ## reads all the agent has written and handles each whole line that is JSON (anything else it prints is left
  ## alone); the end of its output means it has stopped
  var tmp: array[65536, char]
  while true:
    let n = posix.read(a.outFd, addr tmp[0], tmp.len)
    if n > 0:
      let old = a.rbuf.len
      a.rbuf.setLen(old + n)
      copyMem(addr a.rbuf[old], addr tmp[0], n)
    elif n == 0:
      a.dead = true
      break
    else: break
  eachLine(a.rbuf, raw):
    let line = raw.strip
    if line.len > 0 and line[0] == '{':
      try: acpHandle(a, parseJson(line))
      except CatchableError: discard

proc acpReadErr(a: AcpAgent) =
  ## reads the agent's error output into a short list of its last lines (each cut to 300 characters), shown when it
  ## fails and in AI: agent…
  var tmp: array[16384, char]
  while true:
    let n = posix.read(a.errFd, addr tmp[0], tmp.len)
    if n <= 0: break
    var chunk = newString(n)
    copyMem(addr chunk[0], addr tmp[0], n)
    let parts = (a.errPart & chunk).split('\n')
    for k in 0 ..< parts.high:
      let l = stripAnsi(parts[k]).strip
      if l.len > 0: a.errTail.add (if l.len > 300: l[0 ..< 300] else: l)
    a.errPart = parts[^1]
    if a.errTail.len > 60: a.errTail = a.errTail[^40 .. ^1]

proc acpPump(ready: HashSet[cint]) =
  ## (the main loop) the agent read and written; requests that took too long given up; the commands it runs followed
  ## — their output into the chat, their end to whoever waits for it; an agent that stopped says why
  let a = acp
  if a == nil: return
  if not a.dead:
    if a.errFd in ready: a.acpReadErr()
    if a.outFd in ready: a.acpRead()
    if a.wbuf.len > 0: a.acpFlush()
    var late: seq[int]
    for id, (_, at, ms) in a.pending:
      if ms > 0 and msSince(at) > ms: late.add id
    for id in late:
      let (cb, _, _) = a.pending[id]
      a.pending.del id
      cb(nil, %*{"code": -32603, "message": "no answer from " & acpTitle() & " in time"})
  for t in a.terms:
    if t.callId.len > 0 and t.callId in a.calls:
      let o = t.job.output & t.job.partial
      if o.len != t.shown:
        t.shown = o.len
        let (mi, ci) = a.calls[t.callId]
        if mi < aiMsgs.len and ci < aiMsgs[mi].calls.len:
          aiMsgs[mi].calls[ci].result = stripAnsi(if o.len > 16000: o[utf8Cut(o, o.len - 16000) .. ^1] else: o)
          inc aiVersion
          needRender = true
    if t.job.done and t.waiters.len > 0:
      for w in t.waiters: a.acpReply(w, acpTermExit(t))
      t.waiters.setLen(0)
  if a.dead and not a.reaped:
    a.reaped = true
    if a.errFd >= 0: a.acpReadErr()
    if not a.state.startsWith("failed"):
      a.state = "failed: " & (if a.errTail.len > 0: a.errTail[^1] else: "it stopped")
    # (the answer under way ends first, saying why; then whatever else waited for the agent)
    if a.turn or a.waiting:
      a.acpTurnEnd("error", "it stopped — " & a.state[8 .. ^1] & " (palette › AI: agent… shows its last words)")
    let waiting = a.pending
    a.pending.clear()
    for id, (cb, _, _) in waiting: cb(nil, %*{"code": -32603, "message": "it stopped"})
    for t in a.terms:
      if t.job != nil and not t.job.done: killProc(t.job.pr)
    if a.pr.pid > 0: discard waitProc(a.pr, 50)
    closeFd(a.inFd)
    closeFd(a.outFd)
    closeFd(a.errFd)
    needRender = true

proc acpFds(fds: var seq[TPollfd]) =
  ## adds the agent's pipes to what the main loop waits on: its output and error output, and its input while there
  ## is something to write
  let a = acp
  if a == nil or a.dead or a.outFd < 0: return
  fds.add TPollfd(fd: a.outFd, events: POLLIN)
  fds.add TPollfd(fd: a.errFd, events: POLLIN)
  if a.wbuf.len > 0: fds.add TPollfd(fd: a.inFd, events: POLLOUT)

# ── the chat's own actions, with an agent ──

proc acpStop() =
  ## Esc while the agent works: session/cancel (it stops and says "cancelled"), what it waits for you about answered
  ## "cancelled"; a prompt that has not gone yet is dropped
  let a = acp
  if a == nil:
    aiBusy = false
    aiPhase = ""
    return
  if a.waiting:
    a.waiting = false
    aiBusy = false
    aiPhase = ""
    acpNotice("Stopped.")
    return
  if not a.turn: return
  a.acpPermsCancel()
  if a.session.len > 0: a.acpNotify("session/cancel", %*{"sessionId": a.session})
  aiPhase = "stopping…"
  needRender = true

proc acpNewChat() =
  ## a new chat: the agent's next prompt opens a new session (the agent keeps running); an answer under way is
  ## stopped and what is left of it no longer shown
  acpWantNewSession = true
  if acp != nil:
    if acp.turn and acp.session.len > 0: acp.acpNotify("session/cancel", %*{"sessionId": acp.session})
    acp.acpPermsCancel()
    acp.turn = false
    acp.waiting = false
    acp.session = ""
    aiBusy = false
    aiPhase = ""
    acp.calls.clear()
    acp.msgIds.clear()
    acp.planMsg = -1
    acp.turnStart = -1

proc acpForget() =
  ## (ned's own assistant after an agent's chat) the agent's calls written into its replies as lines, so that ned's
  ## requests carry no calls the model never made
  for m in aiMsgs.mitems:
    if m.role != 1: continue
    var keep: seq[AiCall]
    for c in m.calls:
      if c.name.startsWith("acp:"): m.text.add (if m.text.len > 0: "\n" else: "") & "→ " & c.args
      else: keep.add c
    m.calls = keep

proc acpCommandNames(): seq[string] =
  ## the agent's own /commands, for completing them in the chat
  if acp != nil:
    for (n, _) in acp.commands: result.add "/" & n

proc acpIsCommand(t: string): bool =
  ## whether a message starts with one of the agent's own /commands (it goes to the agent as it is)
  if acp == nil or t.len < 2 or t[0] != '/': return false
  let sp = t.find(' ')
  let cmd = (if sp > 0: t[1 ..< sp] else: t[1 .. ^1]).toLowerAscii
  for (n, _) in acp.commands:
    if n.toLowerAscii == cmd: return true
  false

# ── choosing an agent, its mode and its options ──

proc acpUse(name: string) =
  ## the AI dock talks to this agent from now on ("" for ned's own assistant): a new chat, the setting kept
  if name == acpName(): return
  aiNewChat()
  if acp != nil: acpStopAgent()
  setSetting("ai.agentServer", %name)
  info(if name.len == 0: "The AI dock uses ned's own assistant (" & cfgAiProvider & ")"
       else: "The AI dock uses " & name & " — it starts with your first message")

proc acpAddPreset(key, title: string, cmd: seq[string]) =
  ## adds a known agent to ai.agentServers (its command) and uses it
  var all = settingNode("ai.agentServers")
  all = if all == nil or all.kind != JObject: newJObject() else: all.copy
  if not all.hasKey(key): all[key] = %*{"command": cmd[0], "args": cmd[1 .. ^1]}
  setSetting("ai.agentServers", all)
  acpUse(key)
  if findExe(cmd[0]).len == 0:
    warn(title & " runs with " & cmd[0] & ", which is not installed: " &
         (if cmd[0] == "npx": "pkg install nodejs (Termux), or Node.js 22 from nodejs.org" else: "install it first"))

proc acpChooseAgent() =
  ## AI: choose agent — ned's own assistant, the agents in ai.agentServers, and known ones to add with a tap
  var items: seq[(string, string, Action)]
  items.add act("ned's own assistant" & (if not acpOn(): "  ✓" else: ""), cfgAiProvider & " · " &
                (if aiModel().len > 0: aiModel() else: "no model"), proc() = acpUse(""))
  var have: seq[string]
  let all = settingNode("ai.agentServers")
  if all != nil and all.kind == JObject:
    for k, v in all:
      have.add k
      let kk = k
      let detail = acpCmdOf(v).join(" ")
      capture kk, detail:
        items.add act(kk & (if kk == acpName(): "  ✓" else: ""), detail, proc() = acpUse(kk))
  for (key, title, cmd) in AcpPresets:
    if key in have: continue
    let k = key
    let t = title
    let c = cmd
    capture k, t, c:
      items.add act("+ " & t, c.join(" "), proc() = acpAddPreset(k, t, c))
  items.add act("Other agent… (ai.agentServers)", "any program that speaks ACP", proc() =
    openSettingsUi("ai.agentServers"))
  openActions("AI agent", items)

func acpOptionsOf(o: JsonNode): seq[(string, string, string)] =
  ## the values an option may take: (value, name, description) — options in groups taken out of their groups
  for x in jitems(o{"options"}):
    if x{"options"} != nil:
      for y in jitems(x{"options"}): result.add (y{"value"}.getStr, y{"name"}.getStr, y{"description"}.getStr)
    else: result.add (x{"value"}.getStr, x{"name"}.getStr, x{"description"}.getStr)

proc acpSetOption(a: AcpAgent, o: JsonNode, value: string) =
  ## session/set_config_option: one of the agent's options (mode, model, effort …) set; its new options kept
  let cid = if o{"configId"}.getStr.len > 0: o{"configId"}.getStr else: o{"id"}.getStr
  let params = if a.proto == 2: %*{"sessionId": a.session, "configId": cid, "type": "id", "value": value}
               else: %*{"sessionId": a.session, "configId": cid, "value": value}
  a.acpCall("session/set_config_option", params, proc(res, err: JsonNode) =
    if err != nil:
      warn(acpTitle() & ": " & acpErrText(err))
      return
    if res != nil and res{"configOptions"} != nil: a.config = res{"configOptions"}
    info(acpTitle() & ": " & o{"name"}.getStr & " → " & value)
    inc aiVersion
    needRender = true)

proc acpChooseOption(category: string) =
  ## the agent's options (its mode, model, effort … — those of one category when given), and their values to choose
  let a = acp
  if a == nil or a.session.len == 0:
    info("Send a message first: " & acpTitle() & " says what it offers when the conversation starts")
    return
  var opts: seq[JsonNode]
  for o in jitems(a.config):
    if category.len == 0 or o{"category"}.getStr == category: opts.add o
  if opts.len == 0 and category == "mode" and a.modes != nil and a.modes.kind == JObject:
    # (version 1's modes, for an agent without options)
    var items: seq[(string, string, Action)]
    for m in jitems(a.modes{"availableModes"}):
      let id = m{"id"}.getStr
      let label = m{"name"}.getStr & (if id == a.modes{"currentModeId"}.getStr: "  ✓" else: "")
      let detail = m{"description"}.getStr
      capture id, label, detail:
        items.add act(label, detail, proc() =
          a.acpCall("session/set_mode", %*{"sessionId": a.session, "modeId": id}, proc(res, err: JsonNode) =
            if err != nil: warn(acpTitle() & ": " & acpErrText(err))
            else:
              a.modes["currentModeId"] = %id
              inc aiVersion))
    openActions(acpTitle() & ": mode", items)
    return
  if opts.len == 0:
    info(acpTitle() & " has no " & (if category.len > 0: category & " to choose" else: "options"))
    return
  proc valuesMenu(o: JsonNode) =
    ## the values of one option, the current one ticked
    var items: seq[(string, string, Action)]
    for (v, n, d) in acpOptionsOf(o):
      let vv = v
      let label = n & (if v == o{"currentValue"}.getStr: "  ✓" else: "")
      let detail = d
      capture vv, label, detail:
        items.add act(label, detail, proc() = a.acpSetOption(o, vv))
    openActions(acpTitle() & ": " & o{"name"}.getStr, items)
  if opts.len == 1:
    valuesMenu(opts[0])
    return
  var items: seq[(string, string, Action)]
  for o in opts:
    let oo = o
    var cur = o{"currentValue"}.getStr
    for (v, n, _) in acpOptionsOf(o):
      if v == cur: cur = n
    let shownNow = cur
    capture oo, shownNow:
      items.add act(oo{"name"}.getStr, shownNow, proc() = valuesMenu(oo))
  openActions(acpTitle() & ": options", items)

proc acpModeText(): string =
  ## the agent's mode now, by its name ("" when it has none)
  let a = acp
  if a == nil: return ""
  for o in jitems(a.config):
    if o{"category"}.getStr == "mode":
      for (v, n, _) in acpOptionsOf(o):
        if v == o{"currentValue"}.getStr: return n
  if a.modes != nil and a.modes.kind == JObject:
    for m in jitems(a.modes{"availableModes"}):
      if m{"id"}.getStr == a.modes{"currentModeId"}.getStr: return m{"name"}.getStr
  ""

proc acpSignIn(a: AcpAgent) =
  ## signing in: a way the agent offers — one it does itself (authenticate), or one in a terminal of ned's, where you
  ## answer its questions — then the conversation opens again with your next message
  var items: seq[(string, string, Action)]
  for m in jitems(a.authMethods):
    let mm = m
    let id = if m{"id"}.getStr.len > 0: m{"id"}.getStr else: m{"methodId"}.getStr
    capture mm, id:
      items.add act(mm{"name"}.getStr, mm{"description"}.getStr, proc() =
        if mm{"type"}.getStr == "terminal":
          var line = ""
          for k, v in acpPairs(mm{"env"}): line.add quoteShell(k & "=" & v.getStr) & " "
          if line.len > 0: line = "env " & line
          for x in a.cmd & acpStrs(mm{"args"}): line.add quoteShell(x) & " "
          terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), rootDir, line)
          terms[^1].name = "sign in"
          curTerm = terms.high
          setPanel(pkTerminal)
          focus = fPanel
          a.session = ""
        else:
          let onLogin = proc(res, err: JsonNode) =
            if err != nil: warn(acpTitle() & ": " & acpErrText(err))
            else:
              a.state = "ready"
              info("Signed in to " & acpTitle() & " — send your message again")
              inc aiVersion
          a.acpCall((if a.proto == 2: "auth/login" else: "authenticate"), %*{"methodId": id}, onLogin, 600_000))
  if items.len == 0:
    info(acpTitle() & " offers no way to sign in from ned: sign in with its own program, then restart it here")
    return
  openActions("Sign in to " & acpTitle(), items)

proc cmdAcpAgent() =
  ## AI: agent — the agent in use with its state and command; choose another, its mode and options, sign in, see its
  ## last lines of output, restart it
  if not acpOn():
    acpChooseAgent()
    return
  let a = acpEnsure()
  var items: seq[(string, string, Action)]
  let st = if a == nil: "not started" else: a.state
  items.add act("● " & acpTitle() & (if a != nil and a.version.len > 0: " " & a.version else: ""),
                st & (if a != nil and a.proto > 0: " · ACP " & $a.proto else: ""), proc() =
    var body = (if a != nil: a.cmd.join(" ") else: "") & "\n\n" & st & "\n"
    if a != nil and a.errTail.len > 0: body.add "\n" & a.errTail[max(0, a.errTail.len - 8) .. ^1].join("\n")
    openDialog(acpTitle(), body, @[("OK", 'y')], proc(c: char) = discard))
  items.add act("Choose another agent…", "or ned's own assistant", proc() = acpChooseAgent())
  if a != nil and a.session.len > 0:
    items.add act("Mode…", acpModeText(), proc() = acpChooseOption("mode"))
    items.add act("Options…", "model, effort … as the agent offers them", proc() = acpChooseOption(""))
  if a != nil and (a.state == "sign in" or a.authMethods != nil and a.authMethods.len > 0):
    items.add act("Sign in…", "", proc() = a.acpSignIn())
  items.add act("↻ Restart the agent", "a new conversation too", proc() =
    acpStopAgent("restarting")
    acpWantNewSession = true
    discard acpEnsure()
    info("Restarting " & acpTitle() & "…"))
  openActions("AI agent", items)

proc acpHeader(): string =
  ## the conversation's size for the dock's top row: used of the most, and the cost when the agent says it ("" when it
  ## says neither)
  let a = acp
  if a == nil or a.sizeTok <= 0: return (if a != nil: a.cost else: "")
  fmtTokens(a.usedTok) & "/" & fmtTokens(a.sizeTok) & (if a.cost.len > 0: " " & a.cost else: "")
