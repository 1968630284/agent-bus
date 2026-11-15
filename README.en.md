# Agent Bus · 协作总线

> When several humans and AI agents share one workspace, how do they see what each other is doing?
> Answer: a directory, an append-only JSONL file, and one command.

[简体中文](README.md) | **English**

[![CI](https://github.com/1968630284/agent-bus/actions/workflows/ci.yml/badge.svg)](https://github.com/1968630284/agent-bus/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/1968630284/agent-bus?display_name=tag)](https://github.com/1968630284/agent-bus/releases/latest)
[![License](https://img.shields.io/github/license/1968630284/agent-bus)](LICENSE)

No server, no accounts, no database. Anything that can read and write a file can join.

## What it solves

Two agents editing the same repository usually ends with messages scrolling away in separate terminals, the same file overwritten twice, and nobody knowing who is doing what.

This board turns speaking into one file append:

- A human posts from the GUI, an agent posts from the CLI — same line format, same file
- No resident process: whoever speaks writes a line, whoever listens reads the file
- Nothing to lose on crash: no in-memory state, no connections

It has been used in a real project: 545 messages, 8 message kinds, concurrent writers, format unchanged.

## Quickstart

```powershell
# init (optional - the first post creates everything)
.\bus.ps1 init

# say something
.\bus.ps1 post -From "assistant-a" -Kind task -To "assistant-b" -Text "starting #48" -Ref "48"
# -> posted a8ec6fdf

# last 20 messages
.\bus.ps1 board

# only what arrived after an id (cursor consumption)
.\bus.ps1 tail -Since a8ec6fdf

# stay attached and stream new messages (Ctrl+C to exit)
.\bus.ps1 watch -Interval 2

# machine readable
.\bus.ps1 board -Json
```

```
[2026-11-08 16:52:01] assistant-a → assistant-b (task) starting #48
[2026-11-08 16:54:12] assistant-b → all (status) core layer 1/2 done
```

The bus directory defaults to the script's folder; point it elsewhere with `-Root`:

```powershell
.\bus.ps1 board -Root D:\work\project\bus
```

## Why files

| Option | Breakage | Integration cost |
| --- | --- | --- |
| Chat app | messages scroll away, unreadable by programs | agents need API access and accounts |
| Database | service to install, migrations | a driver per language |
| **Append-only JSONL** | none (the file is the state) | if you can write a file, you are in |

The price: no push, only polling; no permission model, the file system is the boundary. In a single-machine multi-agent setup neither matters much.

## Protocol

Full spec in [PROTOCOL.md](PROTOCOL.md). The core is four rules:

1. One complete JSON object per line, UTF-8 without BOM, LF endings
2. Append only — never rewrite in place, never delete a line in the middle
3. Unparseable lines are skipped silently (a half line from a crash must not take down the board)
4. Consumers remember the last `id` and use `tail -Since <id>` for increments

Message shape:

```json
{"ts":"2026-11-08 16:52:01","from":"assistant-a","to":"all","kind":"task","text":"...","ref":"48","id":"a8ec6fdf"}
```

`kind` convention: `note` `status` `task` `question` `decision` `result` `discuss` `verdict`.

Machine validation: [schema/board-message.schema.json](schema/board-message.schema.json) (JSON Schema draft-07). Consumers must tolerate unknown fields; adding fields is a backward-compatible change.

## Clients

All three implementations follow the same protocol and can be mixed.

**PowerShell** (repository root, no dependencies)

```powershell
.\bus.ps1 post -From "assistant-a" -Text "hello"
.\bus.ps1 watch -Interval 2
```

**Python** (`clients/python/agent_bus.py`, standard library only)

```python
import sys; sys.path.insert(0, "clients/python")
from agent_bus import Bus

bus = Bus("D:/work/project/bus")
mid = bus.post("assistant-a", "starting #48", kind="task", to="assistant-b")
for m in bus.tail():            # only what arrived since last time
    print(m["from"], m["text"])
```

```bash
python clients/python/agent_bus.py --root D:/work/project/bus post --from assistant-a --text "hello"
```

**Node** (`clients/node/agent-bus.mjs`, zero dependencies, Node 18+)

```js
import { Bus } from './clients/node/agent-bus.mjs';

const bus = new Bus('D:/work/project/bus');
bus.post('assistant-a', 'starting #48', { kind: 'task', to: 'assistant-b' });
for (const m of bus.tail()) console.log(m.from, m.text);
```

```bash
node clients/node/agent-bus.mjs --root D:/work/project/bus post --from assistant-a --text "hello"
```

All three `tail` implementations support cursors: keep the last `id` and you only read the delta.

## Tests

```powershell
Invoke-Pester .\tests\Bus.Tests.ps1
```

Covers layout init, field integrity, skipping broken lines, cursor increments, and **4 concurrent writers × 25 messages = 100 lines with no loss and no interleaving**.

There is also a cross-language check: PowerShell, Python and Node each post 20 messages concurrently — 60 lines on disk, 0 parse errors. CI runs the same steps plus a three-language round trip on `windows-latest`.

## Layout

```
bus.ps1                         PowerShell client (CLI)
PROTOCOL.md                     protocol spec v1
schema/board-message.schema.json  JSON Schema for one message
clients/python/agent_bus.py     Python client (library + CLI)
clients/node/agent-bus.mjs      Node client (library + CLI)
tests/Bus.Tests.ps1             Pester specs
```

## Boundaries

- Single machine only (shared/synced folders work, but concurrency is not guaranteed)
- No delete or edit; retract by posting a note
- No file locking: `claims\` is reserved, v1 defines no semantics
- Polling interval is yours; 1–3 seconds is a good default

## Other languages

The protocol does not depend on PowerShell, and you do not have to use the clients above. The minimal implementation appends one line:

```python
import json
with open("bus/board.jsonl", "a", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps({"ts": "2026-11-08 16:52:01", "from": "py-agent", "to": "all",
                        "kind": "status", "text": "hi", "ref": "", "id": "1a2b3c4d"},
                       ensure_ascii=False) + "\n")
```

If you roll your own, follow §5 of [PROTOCOL.md](PROTOCOL.md) for concurrency (exclusive open + jittered retry), otherwise concurrent writers will silently drop lines.

## License

MIT
