#!/usr/bin/env python3
"""agent_bus —— 协作总线的 Python 客户端（仅标准库，无第三方依赖）。

    from agent_bus import Bus
    bus = Bus("D:/work/project/bus")
    mid = bus.post("助手A", "48 号开工", kind="task", to="助手B")
    for m in bus.tail():          # 只拿上次之后的新消息
        print(m["from"], m["text"])

命令行（便于 shell 里直接说话）：
    python agent_bus.py post --from 助手A --kind task --text "hello"
    python agent_bus.py board --limit 10
    python agent_bus.py tail --since a8ec6fdf
"""

from __future__ import annotations

import argparse
import json
import os
import random
import time
import uuid
from datetime import datetime
from typing import Iterable, Optional

DEFAULT_ROOT = os.environ.get("AGENT_BUS_ROOT", ".")


class Bus:
    """一块 append-only 的共享白板。目录里只有 board.jsonl 和 agents.json。"""

    def __init__(self, root: Optional[str] = None) -> None:
        self.root = os.path.abspath(root or DEFAULT_ROOT)
        os.makedirs(os.path.join(self.root, "claims"), exist_ok=True)
        self._ensure("board.jsonl", "")
        self._ensure("agents.json", "{\n}")

    # ---------- 路径与初始化 ----------
    def _path(self, name: str) -> str:
        return os.path.join(self.root, name)

    def _ensure(self, name: str, content: str) -> None:
        path = self._path(name)
        if os.path.exists(path):
            return
        try:
            with open(path, "x", encoding="utf-8", newline="\n") as f:
                f.write(content)
        except FileExistsError:
            pass  # 别的进程刚建好，正常

    # ---------- 写 ----------
    def post(self, sender: str, text: str, kind: str = "note",
             to: str = "all", ref: str = "") -> str:
        msg = {
            "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "from": sender,
            "to": to,
            "kind": kind,
            "text": text,
            "ref": ref,
            "id": uuid.uuid4().hex[:8],
        }
        line = json.dumps(msg, ensure_ascii=False, separators=(",", ":")) + "\n"
        path = self._path("board.jsonl")
        for _ in range(40):
            try:
                with open(path, "a", encoding="utf-8", newline="\n") as f:
                    f.write(line)
                break
            except OSError:
                # 并发追加时 Windows 会报共享冲突，短抖动重试即可
                time.sleep(0.02 + random.random() * 0.06)
        else:
            raise RuntimeError("写总线失败: " + path)
        self._touch_agent(sender)
        return msg["id"]

    def _touch_agent(self, sender: str) -> None:
        """成员表是派生数据，写失败不影响消息本身。"""
        if not sender:
            return
        path = self._path("agents.json")
        try:
            try:
                with open(path, encoding="utf-8") as f:
                    agents = json.load(f) or {}
            except Exception:
                agents = {}
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            entry = agents.get(sender) or {"first_seen": now}
            entry["last_seen"] = now
            entry.setdefault("note", "发布留言")
            agents[sender] = entry
            data = json.dumps(agents, ensure_ascii=False, indent=2)
            for _ in range(12):
                try:
                    with open(path, "w", encoding="utf-8", newline="\n") as f:
                        f.write(data)
                    return
                except OSError:
                    time.sleep(0.02 + random.random() * 0.06)
        except Exception:
            pass

    # ---------- 读 ----------
    def read(self, limit: int = 20) -> list:
        msgs = self._all()
        return msgs[-limit:] if limit > 0 else msgs

    def tail(self, since: Optional[str] = None, limit: int = 20) -> list:
        msgs = self._all()
        if not since:
            return msgs[-limit:]
        for i in range(len(msgs) - 1, -1, -1):
            if msgs[i].get("id") == since:
                return msgs[i + 1:]
        return msgs[-limit:]  # 游标找不到（板子被重写）时退回最近 N 条

    def _all(self) -> list:
        path = self._path("board.jsonl")
        out = []
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue  # 崩溃留下的半行，跳过
        except FileNotFoundError:
            pass
        return out


def _print(msgs: Iterable[dict]) -> None:
    for m in msgs:
        print("[{ts}] {f} → {to} ({kind}) {text}".format(
            ts=m.get("ts"), f=m.get("from"), to=m.get("to"),
            kind=m.get("kind"), text=m.get("text")))


def main() -> None:
    ap = argparse.ArgumentParser(description="协作总线命令行")
    ap.add_argument("--root", default=None, help="总线目录（默认 AGENT_BUS_ROOT 或当前目录）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("post", help="发一条留言")
    p.add_argument("--from", dest="sender", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--kind", default="note")
    p.add_argument("--to", default="all")
    p.add_argument("--ref", default="")

    b = sub.add_parser("board", help="看最近 N 条")
    b.add_argument("--limit", type=int, default=20)
    b.add_argument("--json", action="store_true")

    t = sub.add_parser("tail", help="只取某条之后的新消息")
    t.add_argument("--since", default=None)
    t.add_argument("--limit", type=int, default=20)
    t.add_argument("--json", action="store_true")

    args = ap.parse_args()
    bus = Bus(args.root)

    if args.cmd == "post":
        print("posted " + bus.post(args.sender, args.text, args.kind, args.to, args.ref))
    elif args.cmd == "board":
        msgs = bus.read(args.limit)
        print(json.dumps(msgs, ensure_ascii=False, indent=2) if args.json else "", end="")
        if not args.json:
            _print(msgs)
    elif args.cmd == "tail":
        msgs = bus.tail(args.since, args.limit)
        print(json.dumps(msgs, ensure_ascii=False, indent=2) if args.json else "", end="")
        if not args.json:
            _print(msgs)


if __name__ == "__main__":
    main()
