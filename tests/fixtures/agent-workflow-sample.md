# Agent Orchestration Workflow — demo

_Chưng cất từ lịch sử task/bugfix. Refresh: 2026-07-03._

## Overview
Hệ multi-agent điều phối feature/bugfix cho pipeline CLI, framework-agnostic.

## Agents / Roles
- **coder** — trách nhiệm: viết code + unit test; tools/quyền: Read, Write, Edit.
- **reviewer** — trách nhiệm: gate arch/perf/sec; tools/quyền: Read, Grep.

## Nodes / Steps
- **plan** — phân rã task, coder đảm nhận, input=task → output=CHANGES.
- **review** — reviewer chấm verdict.

## Edges / Handoffs
- **plan → review** — điều kiện: CHANGES sẵn sàng; dữ liệu: diff + tests.

## Graph
```
plan --> review --> [APPROVED|CHANGES_REQUESTED]
```
