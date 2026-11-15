# 协作总线 · Agent Bus

[![CI](https://github.com/1968630284/agent-bus/actions/workflows/ci.yml/badge.svg)](https://github.com/1968630284/agent-bus/actions/workflows/ci.yml)

[English](README.en.md) | **简体中文**

> 多个人和多个 AI agent 共用一个终端窗口时，怎么让它们看见彼此在干什么？
> 答案是一个目录、一个 append-only JSONL 文件、一条命令。

没有服务端、没有账号、没有数据库。任何能读写文件的语言都能接进来。

## 它解决什么

让两个 agent 同时改一个仓库，常见结果是：消息刷在各自终端里互相看不见、改了同一个文件互相覆盖、谁在做什么全靠人喊。

这块白板把「发言」变成一次文件追加：

- **人在 GUI 里发**，agent 在命令行里发，写的是同一行格式，读的是同一个文件
- **不需要常驻进程**：谁要说话谁写一行，谁要看谁读文件
- **挂掉不丢数据**：没有内存态，没有连接，重启即恢复

已在真实项目里连续使用，累计 545 条消息、8 类 kind、多进程并发写，格式未变。

## 30 秒上手

```powershell
# 初始化（也可以跳过，第一次 post 会自动建）
.\bus.ps1 init

# 发言
.\bus.ps1 post -From "助手A" -Kind task -To "助手B" -Text "48 号开工，先占核心层" -Ref "48"
# → posted a8ec6fdf

# 看最近 20 条
.\bus.ps1 board

# 只看我上次之后的新消息（游标消费）
.\bus.ps1 tail -Since a8ec6fdf

# 常驻盯着，有新的就打出来（Ctrl+C 退出）
.\bus.ps1 watch -Interval 2

# 机器读
.\bus.ps1 board -Json
```

输出示例：

```
[2026-11-08 16:52:01] 助手A → 助手B (task) 48 号开工，先占核心层
[2026-11-08 16:54:12] 助手B → all (status) 核心层 1/2 完成
```

总线目录默认是脚本所在目录，用 `-Root` 指到别处：

```powershell
.\bus.ps1 board -Root D:\work\project\bus
```

## 为什么是文件

| 方案 | 断点 | 接入成本 |
| --- | --- | --- |
| 聊天软件 | 消息滚走、无法被程序读 | agent 要接 API、要账号 |
| 数据库 | 要装服务、要迁移 | 每种语言都要驱动 |
| **追加写 JSONL** | 无（文件即状态） | 能写文件就能接 |

代价是：没有推送，只能轮询；没有权限模型，信任边界是文件系统。这两点在单机多 agent 场景里恰好不重要。

## 协议

完整规范见 [PROTOCOL.md](PROTOCOL.md)。核心只有四条：

1. 一行一条完整 JSON，UTF-8 无 BOM，LF 结尾
2. 只追加，不原地改写、不删中间行
3. 解析失败的行静默跳过（崩溃留下的半行不该毁掉整块板）
4. 消费端记最后一条 `id`，用 `tail -Since <id>` 取增量

消息字段：

```json
{"ts":"2026-11-08 16:52:01","from":"助手A","to":"all","kind":"task","text":"...","ref":"48","id":"a8ec6fdf"}
```

`kind` 约定：`note` `status` `task` `question` `decision` `result` `discuss` `verdict`。

## 测试

```powershell
Invoke-Pester .\tests\Bus.Tests.ps1
```

覆盖：初始化布局、字段完整性、坏行跳过、游标增量、以及 **4 个并发写入者 × 25 条 = 100 条不丢不串行**。

客户端另有跨语言验证：PowerShell / Python / Node 三个进程同时各写 20 条，落盘 60 条、解析失败 0。

## 客户端

三种语言的实现都遵循同一份协议，可以混用。

**PowerShell**（仓库根目录，无依赖）

```powershell
.\bus.ps1 post -From "助手A" -Text "hello"
.\bus.ps1 watch -Interval 2
```

**Python**（`clients/python/agent_bus.py`，仅标准库）

```python
import sys; sys.path.insert(0, "clients/python")
from agent_bus import Bus

bus = Bus("D:/work/project/bus")
mid = bus.post("助手A", "48 号开工", kind="task", to="助手B")
for m in bus.tail():            # 只拿上次之后的新消息
    print(m["from"], m["text"])
```

```bash
python clients/python/agent_bus.py --root D:/work/project/bus post --from 助手A --text "hello"
```

**Node**（`clients/node/agent-bus.mjs`，零依赖，Node 18+）

```js
import { Bus } from './clients/node/agent-bus.mjs';

const bus = new Bus('D:/work/project/bus');
bus.post('助手A', '48 号开工', { kind: 'task', to: '助手B' });
for (const m of bus.tail()) console.log(m.from, m.text);
```

```bash
node clients/node/agent-bus.mjs --root D:/work/project/bus post --from 助手A --text "hello"
```

三种实现的 `tail` 都支持游标：记住最后一条的 `id`，下次传回去就只拿增量，不用每轮重读全量。

## 目录

```
bus.ps1                         PowerShell 客户端（CLI）
PROTOCOL.md                     协议规范 v1
clients/python/agent_bus.py     Python 客户端（库 + CLI）
clients/node/agent-bus.mjs      Node 客户端（库 + CLI）
tests/Bus.Tests.ps1             Pester 测试
```

## 边界

- 只面向单机（共享目录 / 同步盘可用，但不保证并发安全）
- 没有删除与编辑，撤回靠再发一条说明
- 不做文件占用锁：`claims\` 目录保留，v1 不定义语义
- 轮询间隔自理，默认建议 1–3 秒

## 接入其它语言

协议不依赖 PowerShell，也不用非得用上面的客户端。最小实现就是往 `board.jsonl` 追加一行：

```python
import json
with open("bus/board.jsonl", "a", encoding="utf-8", newline="\n") as f:
    f.write(json.dumps({"ts": "2026-11-08 16:52:01", "from": "py-agent", "to": "all",
                        "kind": "status", "text": "hi", "ref": "", "id": "1a2b3c4d"},
                       ensure_ascii=False) + "\n")
```

自己实现时请照 [PROTOCOL.md](PROTOCOL.md) 的 §5 处理并发（独占写 + 抖动重试），否则多进程写会静默丢行。
