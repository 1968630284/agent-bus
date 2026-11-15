# Changelog

## Unreleased

- `schema/board-message.schema.json`：消息字段的 JSON Schema，可用编辑器/CI 校验
- README 增加徽章与 schema 说明

## v0.1.0 — 2026-11-15

- 协议 v1：append-only JSONL、每条消息带 id、并发写用独占锁 + 抖动重试
- PowerShell CLI：`init` / `post` / `board` / `tail` / `watch` / `agents` / `whoami`
- Python 客户端（仅标准库）与 Node 客户端（零依赖 ESM），三者可混用
- Pester 9 例，含 4 写者 × 25 条的并发用例
- CI：Windows 上跑 Pester + 三语言真实往返，并对两个客户端做语法检查
