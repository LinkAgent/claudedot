# 状态指示与提示消息需求文档 v1.0

> 来源：[#33](https://github.com/LinkAgent/claudedot/issues/33)（Epic）。本文件把分散在 Epic 与子
> issue（[#30](https://github.com/LinkAgent/claudedot/issues/30) /
> [#31](https://github.com/LinkAgent/claudedot/issues/31) /
> [#32](https://github.com/LinkAgent/claudedot/issues/32)）中的需求落档，作为状态模型的可追溯依据。
> 实现细节以 [`CLAUDE.md`](../CLAUDE.md) 的「Status priority & colors」一节为准；本文件描述**需求**，
> 二者如有冲突以代码与 `CLAUDE.md` 现状为准。

## 1. 目标

把 Claude Dot 的「会话状态灯 + 提示消息」统一到一个清晰的状态模型，并对齐 Claude Desktop welcome
页的会话筛选规则，使菜单栏猫头鹰颜色、徽标数字、弹窗状态点三者始终读作同一种状态。

## 2. 概念 4 态模型（lifecycle hook 驱动）

状态由 Claude Code 的 lifecycle hook 事件驱动。概念上分为 4 态：

```
PreToolUse / PostToolUse    →  Working    （工作中，无需操作）
Notification                →  Needs You  （需你处理）
  ├─ permission_prompt      →    权限确认变体（急促）
  └─ idle_prompt            →    闲置提醒变体（温和）
Stop                        →  Idle/Done  （已完成，查看结果）
hook exit 2 / runtime error →  Error      （错误）
```

要点：原生 `PreToolUse` / `PostToolUse` 粒度过细，**不应**直接当作「需要用户」。真正精确的
Needs You 信号是 **Notification**，并按 matcher 细分为权限确认（急促）与闲置提醒（温和）。

## 3. 概念 4 态 ↔ 实现 5 态映射

实现层使用 5 个 `Status` 值（见 `app/Sources/Model.swift`），与概念 4 态对应如下：

| 概念态 (v1.0)   | 实现 `Status`      | 颜色 / 行为 |
| --------------- | ------------------ | ----------- |
| Working         | `running`          | 绿；agent 正在工作，无需操作 |
| Needs You（急促）| `waiting`          | 黄；显式选择/批准（权限、AskUserQuestion、ExitPlanMode）；显示批准面板；排序最高 |
| Needs You（温和）| `done`             | 黄（同色）；回合以提问结尾的「Needs input」；不显示面板；排序在 running 之下 |
| Idle/Done       | `idle`             | 灰；纯粹完成（无提问）的回合不进入列表，**隐藏** |
| Error           | `error`            | 红；工具调用失败（hook 叠加，仅在时效窗口内） |

说明：
- 概念上的「Idle/Done = 已完成、查看结果」在实现中拆成两类：以**提问结尾**的回合升级为
  `done`（需要你回看并回应），而纯粹完成的回合归为 `idle` 并隐藏，避免噪声。
- `waiting` 与 `done` 共用同一种黄色并都计入徽标，但 `waiting` 更紧急（排序更高、显示批准面板）。

## 4. 聚合与徽标

- 聚合图标取最大值：`error (4) > waiting (3) > running (2) > done (1) > idle (0)`。
- 菜单栏徽标数字 (`badgeCount`) 与猫头鹰颜色一致：红→error 数，黄→needs-input 数（`waiting + done`），
  绿→running 数 —— 数字与颜色始终对应同一状态。
- 一个超过 90s（`runningLivenessWindow`）仍 running 的会话在聚合中衰减为 idle（除非 `trustedActive`）。

## 5. Notification 细分（#30）

`install_hooks.py` 为 Notification 注册两个 matcher 并传入 `--notify-kind`：

- `permission_prompt` → 急促 `waiting`（需你立即处理的权限/提问）。
- `idle_prompt` → 温和（不升级状态，仅提醒）。

payload 本身没有类型字段（claude-code#11964），所以由 matcher 注入 `notify_kind`，hook 据此区分变体。

## 6. 桌面会话判定与筛选（#31 / #32）

- **桌面状态以 transcript 为准，而非信任 hook**（#31）：Desktop 原生条目的 hook 可能在 agent 停止后
  仍卡在 running。`mergeSessions` 以 `loadDesktop` 的 transcript 扫描（mtime + tail + `lastFocusedAt`）
  驱动桌面状态；hook 仅在**新鲜**（90s 内）时把已结束的 tail 升级为 running，并叠加 error 与待批准详情。
  尾部判定区分 `finished / runningTool / blocking / userTurn`，确保 FINISHED ≠ running，实际 0 running
  时列表不出现 running 行。
- **对齐 welcome 页筛选**（#32）：`loadDesktop` 排除定时任务（cron bot）会话，并通过纯函数
  `filterWelcomeSessions` 收敛集合（丢弃 `isScheduled`；`waiting` 无视时效保留；其余取 24h 窗口内）。

## 7. 验收标准

1. 进入工具调用 → **Working**（绿）。
2. 请求权限/提问 → **Needs You** + 提示；权限（急促）与闲置（温和）**不同**提示。
3. 完成回合产出结果 → **Idle/Done**；以提问结尾则显示为「Needs input」，否则隐藏；**实际 0 running
   时列表无 running 行**。
4. 命令被拦截或运行报错 → **Error**（红）。
5. 桌面端通知开箱即用；VS Code / Linux 通过 hook 补齐。列表对齐 welcome：无定时任务、~24h 窗口。
6. `./run_tests.sh` 全绿（Python hook 测试 + Swift model 测试）。

## 8. 配置注意事项

- `settings.json` 不允许尾随逗号/注释（v1.0.95 起非法配置会整体禁用 hooks）。
- Stop hook 需解析 `stop_hook_active` 以防死循环。
- `Notification` 等事件的 `exit 2` 不可阻断——hook 任何错误一律 `exit 0` 且**不向 stdout 打印**
  （部分 hook stdout 会被注入 Claude 上下文）。

## 9. 状态

Epic [#33](https://github.com/LinkAgent/claudedot/issues/33) 的三个子任务
（[#30](https://github.com/LinkAgent/claudedot/issues/30) /
[#31](https://github.com/LinkAgent/claudedot/issues/31) /
[#32](https://github.com/LinkAgent/claudedot/issues/32)）均已实现并合入；本文件为对应的需求落档。
