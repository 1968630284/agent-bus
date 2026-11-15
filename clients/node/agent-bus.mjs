#!/usr/bin/env node
/**
 * agent_bus —— 协作总线的 Node 客户端（零依赖，Node 18+）。
 *
 *   import { Bus } from './agent-bus.mjs';
 *   const bus = new Bus('D:/work/project/bus');
 *   const id = bus.post('助手A', '48 号开工', { kind: 'task', to: '助手B' });
 *   for (const m of bus.tail()) console.log(m.from, m.text);
 *
 * 命令行：
 *   node agent-bus.mjs post --from 助手A --kind task --text "hello"
 *   node agent-bus.mjs board --limit 10
 *   node agent-bus.mjs tail --since a8ec6fdf
 */
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

function sleepSync(ms) {
  // Node 里没有同步 sleep，用 Atomics.wait 阻塞当前线程
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
         `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export class Bus {
  constructor(root) {
    // null / '' / 未传 都回落到环境变量或当前目录
    this.root = path.resolve(root || process.env.AGENT_BUS_ROOT || '.');
    fs.mkdirSync(path.join(this.root, 'claims'), { recursive: true });
    this.#ensure('board.jsonl', '');
    this.#ensure('agents.json', '{\n}');
  }

  #ensure(name, content) {
    const p = this.#path(name);
    if (fs.existsSync(p)) return;
    try {
      fs.writeFileSync(p, content, { encoding: 'utf8', flag: 'wx' });
    } catch (e) {
      if (e.code !== 'EEXIST') throw e; // 别的进程刚建好，正常
    }
  }

  #path(name) {
    return path.join(this.root, name);
  }

  post(sender, text, { kind = 'note', to = 'all', ref = '' } = {}) {
    const msg = {
      ts: stamp(), from: sender, to, kind, text, ref,
      id: randomUUID().replace(/-/g, '').slice(0, 8),
    };
    const line = JSON.stringify(msg) + '\n';
    const p = this.#path('board.jsonl');
    let ok = false;
    for (let i = 0; i < 40; i++) {
      try {
        fs.appendFileSync(p, line, 'utf8');
        ok = true;
        break;
      } catch {
        sleepSync(20 + Math.floor(Math.random() * 60)); // 共享冲突：短抖动重试
      }
    }
    if (!ok) throw new Error('写总线失败: ' + p);
    this.#touchAgent(sender);
    return msg.id;
  }

  #touchAgent(sender) {
    // 成员表是派生数据，写失败不影响消息本身
    if (!sender) return;
    const p = this.#path('agents.json');
    try {
      let agents = {};
      try { agents = JSON.parse(fs.readFileSync(p, 'utf8') || '{}'); } catch { agents = {}; }
      const now = stamp();
      const entry = agents[sender] || { first_seen: now };
      entry.last_seen = now;
      entry.note = entry.note || '发布留言';
      agents[sender] = entry;
      for (let i = 0; i < 12; i++) {
        try {
          fs.writeFileSync(p, JSON.stringify(agents, null, 2), 'utf8');
          return;
        } catch {
          sleepSync(20 + Math.floor(Math.random() * 60));
        }
      }
    } catch { /* 忽略 */ }
  }

  read(limit = 20) {
    const msgs = this.#all();
    return limit > 0 ? msgs.slice(-limit) : msgs;
  }

  tail(since = null, limit = 20) {
    const msgs = this.#all();
    if (!since) return msgs.slice(-limit);
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].id === since) return msgs.slice(i + 1);
    }
    return msgs.slice(-limit); // 游标找不到时退回最近 N 条
  }

  #all() {
    const p = this.#path('board.jsonl');
    const out = [];
    let raw;
    try { raw = fs.readFileSync(p, 'utf8'); } catch { return out; }
    for (const line of raw.split('\n')) {
      const s = line.trim();
      if (!s) continue;
      try { out.push(JSON.parse(s)); } catch { /* 半行跳过 */ }
    }
    return out;
  }
}

function fmt(m) {
  return `[${m.ts}] ${m.from} → ${m.to} (${m.kind}) ${m.text}`;
}

function main() {
  const argv = process.argv.slice(2);
  const rootIdx = argv.indexOf('--root');
  const root = rootIdx >= 0 ? argv.splice(rootIdx, 2)[1] : null;
  const cmd = argv.shift();
  const opt = (name, dflt) => {
    const i = argv.indexOf(name);
    return i >= 0 ? (argv.splice(i, 2)[1] ?? dflt) : dflt;
  };
  const bus = new Bus(root);

  if (cmd === 'post') {
    const from = opt('--from');
    const text = opt('--text');
    if (!from || !text) {
      console.error('用法: post --from 名字 --text 内容 [--kind note] [--to all] [--ref 引用]');
      process.exit(1);
    }
    console.log('posted ' + bus.post(from, text, {
      kind: opt('--kind', 'note'), to: opt('--to', 'all'), ref: opt('--ref', ''),
    }));
  } else if (cmd === 'board' || cmd === 'tail') {
    const limit = parseInt(opt('--limit', '20'), 10);
    const msgs = cmd === 'tail' ? bus.tail(opt('--since', null), limit) : bus.read(limit);
    if (argv.includes('--json')) console.log(JSON.stringify(msgs, null, 2));
    else msgs.forEach((m) => console.log(fmt(m)));
  } else {
    console.log('用法: node agent-bus.mjs post|board|tail [--root 目录]');
  }
}

// 只有被直接执行时才跑 CLI；被 import 时保持纯库
const isMain = process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
