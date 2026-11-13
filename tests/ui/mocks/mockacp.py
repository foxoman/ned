#!/usr/bin/env python3
"""A scripted ACP agent (Agent Client Protocol, JSON-RPC over stdio) for ned's tests.

Version 1 by default; MOCK_ACP_V2=1 speaks only version 2 (a version 1 initialize gets error -32022);
MOCK_ACP_AUTH=1 wants `authenticate` before a session; MOCK_ACP_LOG=FILE logs what ned sends.
What it does depends on words in the prompt:
  hello            a greeting, in pieces (and the name of a file linked to the prompt)
  think            a thought, then an answer
  read PATH        fs/read_text_file, then its first line
  edit PATH        a tool call asking permission with a diff, then fs/write_text_file (v2: writes it itself)
  run CMD          a tool call asking permission, then terminal/create … wait_for_exit … output … release
  plan             a plan, updated as it goes
  slow             words until it is cancelled (session/cancel), then stopReason "cancelled"
  usage            usage_update: the conversation's size and cost
  mode             says the mode it is in
  picture          says whether a picture came with the prompt
  crash            dies, saying "boom" on its error output
  hostile          nonsense of every kind (bad JSON, wrong types, a 2 MB line, requests ned does not know)
  /compact         its own command
"""
import json, os, sys, threading, time

V2 = os.environ.get('MOCK_ACP_V2') == '1'
AUTH = os.environ.get('MOCK_ACP_AUTH') == '1'
LOG = os.environ.get('MOCK_ACP_LOG')
out_lock = threading.Lock()
waits = {}          # id of a request to ned → [event, answer]
next_id = [1000]
cancelled = threading.Event()
state = {'authed': not AUTH, 'mode': 'ask', 'model': 'small', 'session': 0}


def log(m):
    # what ned sent, one JSON object a line (for the test to read)
    if LOG:
        with open(LOG, 'a') as f:
            f.write(json.dumps(m) + '\n')


def send(m):
    # one message to ned, one line
    with out_lock:
        sys.stdout.write(json.dumps(m) + '\n')
        sys.stdout.flush()


def reply(mid, result):
    # an answer to ned's request
    send({'jsonrpc': '2.0', 'id': mid, 'result': result})


def ask(meth, params, timeout=60):
    # a request to ned, waited for: its result, or {'error': …}
    next_id[0] += 1
    mid = next_id[0]
    ev = threading.Event()
    waits[mid] = [ev, None]
    send({'jsonrpc': '2.0', 'id': mid, 'method': meth, 'params': params})
    ev.wait(timeout)
    return waits.pop(mid)[1] or {'error': 'no answer'}


def update(sid, u):
    # a session/update
    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': sid, 'update': u}})


def say(sid, text, mid='m1'):
    # words of the answer
    u = {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}}
    if V2:
        u['messageId'] = mid
    update(sid, u)


def config():
    # its options: the model
    o = {'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': state['model'],
         'options': [{'value': 'small', 'name': 'Small'}, {'value': 'big', 'name': 'Big'}]}
    o['configId' if V2 else 'id'] = 'model'
    return [o]


def perm(sid, call, title):
    # asks ned for permission about a call: the option chosen, or 'cancelled'
    opts = [{'optionId': 'yes', 'name': 'Allow', 'kind': 'allow_once'},
            {'optionId': 'always', 'name': 'Always allow', 'kind': 'allow_always'},
            {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'}]
    if V2:
        r = ask('session/request_permission', {'sessionId': sid, 'title': title,
                                               'subject': {'type': 'tool_call', 'toolCall': call}, 'options': opts}, 120)
    else:
        r = ask('session/request_permission', {'sessionId': sid, 'toolCall': call, 'options': opts}, 120)
    o = (r.get('result') or {}).get('outcome') or {}
    return o.get('optionId') if o.get('outcome') == 'selected' else 'cancelled'


def turn(sid, mid, prompt):
    # one prompt answered; the end said as the version wants
    texts = [b.get('text', '') for b in prompt if b.get('type') == 'text']
    text = '\n'.join(texts)
    links = [b.get('name', '') for b in prompt if b.get('type') == 'resource_link']
    pics = [b for b in prompt if b.get('type') == 'image']
    words = text.split()
    stop = 'end_turn'
    if V2:
        update(sid, {'sessionUpdate': 'state_update', 'state': 'running'})
    if 'crash' in words:
        sys.stderr.write('boom\n')
        sys.stderr.flush()
        os._exit(3)
    if 'hello' in words:
        say(sid, 'Hello from ')
        say(sid, 'the mock agent' + (' (v2)' if V2 else '') + '.')
        if links:
            say(sid, ' I see the link to ' + links[0] + '.')
        if V2:
            update(sid, {'sessionUpdate': 'agent_message', 'messageId': 'm1',
                         'content': [{'type': 'text', 'text': 'Hello from the mock agent (v2), whole.'}]})
    if 'think' in words:
        u = {'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'Considering the question'}}
        if V2:
            u['messageId'] = 't1'
        update(sid, u)
        say(sid, 'Thought it through.')
    if 'read' in words:
        p = os.path.abspath(words[words.index('read') + 1])
        r = ask('fs/read_text_file', {'sessionId': sid, 'path': p, 'line': 1, 'limit': 1})
        if 'error' in r:
            say(sid, 'Could not read it: ' + str(r['error'].get('message') if isinstance(r['error'], dict) else r['error']))
        else:
            say(sid, 'The file says: ' + r['result']['content'].strip())
    if 'edit' in words:
        p = os.path.abspath(words[words.index('edit') + 1])
        old = open(p).read()
        new = old.replace('hello', 'goodbye')
        call = {'toolCallId': 'edit-1', 'title': 'Edit ' + os.path.basename(p), 'kind': 'edit', 'status': 'pending',
                'locations': [{'path': p}]}
        if V2:
            diff = {'type': 'diff', 'changes': [{'operation': 'modify', 'path': p}],
                    'patch': {'format': 'unified', 'text': '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-' + old.splitlines()[0] +
                              '\n+' + new.splitlines()[0] + '\n'}}
        else:
            diff = {'type': 'diff', 'path': p, 'oldText': old, 'newText': new}
        update(sid, dict(call, sessionUpdate='tool_call_update' if V2 else 'tool_call'))
        choice = perm(sid, {'toolCallId': 'edit-1', 'content': [diff]}, 'Edit ' + os.path.basename(p))
        if choice in ('yes', 'always'):
            if V2:
                open(p, 'w').write(new)
            else:
                ask('fs/write_text_file', {'sessionId': sid, 'path': p, 'content': new})
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'edit-1', 'status': 'completed',
                         'content': [diff]})
            say(sid, 'Edited (' + choice + ').')
        else:
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'edit-1', 'status': 'failed'})
            say(sid, 'Not edited: ' + choice + '.')
    if 'run' in words:
        cmd = ' '.join(words[words.index('run') + 1:]).split('(In the editor')[0].strip()
        call = {'toolCallId': 'run-1', 'title': 'Run ' + cmd, 'kind': 'execute', 'status': 'pending',
                'rawInput': {'command': cmd}}
        update(sid, dict(call, sessionUpdate='tool_call_update' if V2 else 'tool_call'))
        choice = perm(sid, {'toolCallId': 'run-1'}, 'Run ' + cmd)
        if choice in ('yes', 'always') and not V2:
            t = ask('terminal/create', {'sessionId': sid, 'command': 'sh', 'args': ['-c', cmd],
                                        'env': [{'name': 'MOCK_VAR', 'value': 'from-agent'}], 'outputByteLimit': 4000})
            tid = t['result']['terminalId']
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'run-1', 'status': 'in_progress',
                         'content': [{'type': 'terminal', 'terminalId': tid}]})
            ex = ask('terminal/wait_for_exit', {'sessionId': sid, 'terminalId': tid}, 60)
            o = ask('terminal/output', {'sessionId': sid, 'terminalId': tid})
            ask('terminal/release', {'sessionId': sid, 'terminalId': tid})
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'run-1', 'status': 'completed'})
            say(sid, 'Exit ' + str(ex['result'].get('exitCode')) + ': ' + o['result']['output'].strip().replace('\n', ' | '))
        else:
            update(sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'run-1', 'status': 'failed'})
            say(sid, 'Not run: ' + choice + '.')
    if 'plan' in words:
        def entries(done):
            return [{'content': 'Read the code', 'priority': 'high', 'status': 'completed'},
                    {'content': 'Change it', 'priority': 'medium', 'status': 'completed' if done else 'in_progress'},
                    {'content': 'Test it', 'priority': 'low', 'status': 'completed' if done else 'pending'}]
        if V2:
            update(sid, {'sessionUpdate': 'plan_update', 'plan': {'type': 'items', 'planId': 'p1', 'entries': entries(False)}})
        else:
            update(sid, {'sessionUpdate': 'plan', 'entries': entries(False)})
        say(sid, 'Planned.')
        time.sleep(0.4)
        if V2:
            update(sid, {'sessionUpdate': 'plan_update', 'plan': {'type': 'items', 'planId': 'p1', 'entries': entries(True)}})
        else:
            update(sid, {'sessionUpdate': 'plan', 'entries': entries(True)})
    if 'slow' in words:
        cancelled.clear()
        for i in range(100):
            if cancelled.wait(0.3):
                stop = 'cancelled'
                break
            say(sid, 'tick ')
    if 'hostile' in words:
        # nonsense of every kind: ned must go on, with nothing in its errors.log
        with out_lock:
            sys.stdout.write('not json at all\n{"half": \n' + '{' * 3000 + '}' * 3000 + '\n[1, 2, 3]\n"a string"\n')
            sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': sid, 'update':
                             {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'x' * 2000000}}}}) + '\n')
            sys.stdout.flush()
        for u in [{'sessionUpdate': 'agent_message_chunk', 'content': 5},
                  {'sessionUpdate': 'agent_message_chunk'},
                  {'sessionUpdate': 'tool_call', 'toolCallId': 7, 'title': ['no'], 'status': 3, 'content': 'nope'},
                  {'sessionUpdate': 'tool_call', 'toolCallId': 'h1', 'title': 'H', 'content': [5, None, {'type': 'diff'},
                   {'type': 'diff', 'path': 9}, {'type': 'terminal', 'terminalId': None}, {'type': 'content'}],
                   'locations': [{'path': None}, 3], 'rawInput': 'just text'},
                  {'sessionUpdate': 'tool_call_update', 'toolCallId': 'h1', 'status': 'completed', 'content': None},
                  {'sessionUpdate': 'tool_call_content_chunk', 'toolCallId': 'nowhere', 'content': None},
                  {'sessionUpdate': 'plan', 'entries': 'not a list'}, {'sessionUpdate': 'plan', 'entries': [None, 3, {}]},
                  {'sessionUpdate': 'plan_update', 'plan': None}, {'sessionUpdate': 'state_update'},
                  {'sessionUpdate': 'available_commands_update', 'availableCommands': [None, {'name': 5}]},
                  {'sessionUpdate': 'current_mode_update', 'currentModeId': None},
                  {'sessionUpdate': 'config_option_update', 'configOptions': 'x'},
                  {'sessionUpdate': 'usage_update', 'used': 'many', 'size': None, 'cost': {'amount': 'lots'}},
                  {'sessionUpdate': 'terminal_output_chunk', 'terminalId': 'none', 'data': '%%%'},
                  {'sessionUpdate': 'something_new', 'whatever': True}, None, 5, 'text']:
            update(sid, u)
        send({'jsonrpc': '2.0', 'method': 'session/update', 'params': None})
        send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': sid}})
        send({'jsonrpc': '2.0', 'id': 99999, 'result': {'stray': True}})
        send({'jsonrpc': '2.0', 'id': 'str-id', 'error': None})
        for meth, prm in [('fs/read_text_file', {'path': 5}), ('fs/read_text_file', {'path': '/no/such/file'}),
                          ('fs/read_text_file', {'path': os.path.abspath('src/demo.nim'), 'line': -5, 'limit': -1}),
                          ('fs/write_text_file', {'path': None, 'content': 3}),
                          ('terminal/output', {'terminalId': 'nope'}), ('terminal/kill', {}),
                          ('terminal/create', {'command': None}), ('session/request_permission', {'options': 'x'}),
                          ('made/up', None)]:
            ask(meth, dict(prm or {}, sessionId=sid) if isinstance(prm, dict) else prm, 10)
        say(sid, 'Still here.')
    if 'usage' in words:
        update(sid, {'sessionUpdate': 'usage_update', 'used': 12345, 'size': 200000,
                     'cost': {'amount': 0.05, 'currency': 'USD'}})
        say(sid, 'Counted.')
    if 'mode' in words:
        say(sid, 'Mode is ' + state['mode'] + ', model ' + state['model'] + '.')
    if 'picture' in words:
        say(sid, ('I got a picture (' + pics[0].get('mimeType', '') + ').') if pics else 'No picture.')
    if text.strip().startswith('/compact'):
        say(sid, 'Compacted.')
    if V2:
        update(sid, {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': stop})
    else:
        reply(mid, {'stopReason': stop})


def main():
    # reads ned's messages: its answers go to whoever waits; its requests and notifications are handled
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        m = json.loads(line)
        log(m)
        mid, meth, p = m.get('id'), m.get('method'), m.get('params') or {}
        if meth is None and mid in waits:
            waits[mid][1] = m
            waits[mid][0].set()
            continue
        if meth == 'initialize':
            if V2 and p.get('protocolVersion') != 2:
                send({'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32022, 'message': 'this agent speaks version 2'}})
                continue
            auth = [{'id': 'mock-login', 'name': 'Mock sign-in', 'description': 'says yes'}] if AUTH else []
            if V2:
                reply(mid, {'protocolVersion': 2, 'info': {'name': 'mock-agent', 'title': 'Mock Agent', 'version': '2.0'},
                            'capabilities': {'session': {'prompt': {'image': {}}}}, 'authMethods': auth})
            else:
                reply(mid, {'protocolVersion': 1, 'agentInfo': {'name': 'mock-agent', 'title': 'Mock Agent', 'version': '1.0'},
                            'agentCapabilities': {'promptCapabilities': {'image': True, 'embeddedContext': True}},
                            'authMethods': auth})
        elif meth in ('authenticate', 'auth/login'):
            state['authed'] = True
            reply(mid, {})
        elif meth == 'session/new':
            if not state['authed']:
                send({'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32000, 'message': 'Authentication required'}})
                continue
            state['session'] += 1
            sid = 's%d' % state['session']
            r = {'sessionId': sid, 'configOptions': config()}
            if not V2:
                r['modes'] = {'currentModeId': state['mode'], 'availableModes': [
                    {'id': 'ask', 'name': 'Ask first'}, {'id': 'code', 'name': 'Code freely'}]}
            reply(mid, r)
            update(sid, {'sessionUpdate': 'available_commands_update',
                         'availableCommands': [{'name': 'compact', 'description': 'compact the conversation'}]})
        elif meth == 'session/prompt':
            sid = p.get('sessionId')
            if V2:
                reply(mid, {'messageId': 'u1'})
            threading.Thread(target=turn, args=(sid, mid, p.get('prompt') or []), daemon=True).start()
        elif meth == 'session/cancel':
            cancelled.set()
        elif meth == 'session/set_mode':
            state['mode'] = p.get('modeId')
            reply(mid, {})
            update(p.get('sessionId'), {'sessionUpdate': 'current_mode_update', 'currentModeId': state['mode']})
        elif meth == 'session/set_config_option':
            if p.get('configId') == 'model':
                state['model'] = p.get('value')
            reply(mid, {'configOptions': config()})
        elif mid is not None:
            send({'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'not here'}})


if __name__ == '__main__':
    main()
