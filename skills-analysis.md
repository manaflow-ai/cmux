# cmux Skills 系统分析报告

## 1. 概述

cmux 项目目前维护 **4 个 skills**，位于 `skills/` 目录下：

| Skill | 功能 | 复杂度 |
|-------|------|--------|
| `cmux` | 核心拓扑控制（窗口、工作区、窗格、表面） | 中 |
| `cmux-browser` | 浏览器自动化（WebView 表面操作） | 高 |
| `cmux-debug-windows` | 调试窗口管理 | 低 |
| `release` | 发布流程自动化 | 中 |

---

## 2. 目录结构分析

```
skills/
├── cmux/
│   ├── SKILL.md                 # 主 skill 文档
│   ├── agents/openai.yaml       # LLM 接口配置
│   └── references/              # 详细参考文档
│       ├── handles-and-identify.md
│       ├── windows-workspaces.md
│       ├── panes-surfaces.md
│       └── trigger-flash-and-health.md
├── cmux-browser/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   ├── references/              # 6 个参考文档
│   │   ├── commands.md
│   │   ├── snapshot-refs.md
│   │   ├── authentication.md
│   │   ├── session-management.md
│   │   ├── video-recording.md
│   │   └── proxy-support.md
│   └── templates/               # 自动化模板
│       ├── form-automation.sh
│       ├── authenticated-session.sh
│       └── capture-workflow.sh
├── cmux-debug-windows/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── scripts/
│       └── debug_windows_snapshot.sh
└── release/
    ├── SKILL.md
    └── agents/openai.yaml
```

---

## 3. 设计模式分析

### 3.1 SKILL.md 格式规范

每个 SKILL.md 遵循统一结构：

```yaml
---
name: <skill-name>
description: <简短描述>
---
# Title

## Core Concepts / Core Workflow
## Fast Start / Workflow
## Examples
## Deep-Dive References (表格)
## Key Files / Script (可选)
```

**优点**：
- 结构清晰，易于导航
- Front matter 支持 skill 注册
- 包含"快速开始"部分，降低使用门槛

### 3.2 agents/openai.yaml 规范

```yaml
interface:
  display_name: "显示名称"
  short_description: "简短描述"
  default_prompt: "默认提示词"
```

**观察**：
- 配置相对简单，仅包含 3 个字段
- 缺少自定义工具定义、参数模式等
- 没有版本字段

### 3.3 参考文档组织

- 按功能域拆分（commands, snapshot, auth, session 等）
- 包含命令映射表（从 agent-browser 迁移）
- 标注已知限制（WKWebView gaps）

### 3.4 模板/脚本

- `.sh` 脚本文件可直接执行
- 模板包含完整的工作流示例

---

## 4. 功能总结

### cmux (核心控制)

| 功能域 | 命令示例 |
|--------|----------|
| 上下文识别 | `cmux identify --json` |
| 拓扑列举 | `cmux list-windows/workspaces/panes` |
| 创建/聚焦/移动 | `cmux new-workspace`, `cmux focus-pane`, `cmux move-surface` |
| 重新排序 | `cmux reorder-surface --before/--after` |
| 视觉提示 | `cmux trigger-flash --surface` |

### cmux-browser (浏览器自动化)

| 功能域 | 命令示例 |
|--------|----------|
| 打开/导航 | `cmux browser open <url>`, `cmux browser <surface> goto` |
| 快照/检查 | `cmux browser <surface> snapshot --interactive` |
| 交互 | `cmux browser <surface> click/fill/type/select` |
| 等待 | `cmux browser <surface> wait --selector/--text/--load-state` |
| 会话管理 | `cmux browser <surface> state save/load` |

### cmux-debug-windows (调试)

- 调试菜单接线（`Sources/cmuxApp.swift`）
- 调试窗口管理（Sidebar/Background/Menu Bar Extra）
- 组合配置快照脚本

### release (发布)

- 版本确定与 bumping
- Changelog 生成与贡献者收集
- PR 创建、CI 监控、合并
- Tag 创建与发布验证

---

## 5. 潜在改进点

### 5.1 基础设施缺失

| 问题 | 建议 |
|------|------|
| 无 skill 注册索引 | 添加 `skills/index.yaml` 或 `skills/SKILLS.md` 索引 |
| 无版本管理 | 在 front matter 添加 `version` 字段 |
| 无测试覆盖 | 添加 skill 解析/验证测试 |
| 无依赖声明 | 声明 skill 间依赖（如 cmux-browser 依赖 cmux） |

### 5.2 agents/openai.yaml 扩展

当前仅 3 字段，建议扩展：

```yaml
interface:
  display_name: "..."
  short_description: "..."
  default_prompt: "..."

version: "1.0.0"
tags: [browser, automation]

tools:  # 声明可用工具
  - name: browser.open
    description: "..."
    parameters: ...

constraints:  # 约束/限制
  - "需要 macOS 环境"
  - "仅支持 WKWebView"
```

### 5.3 文档增强

| 建议 | 理由 |
|------|------|
| 添加错误处理指南 | 帮助调试失败场景 |
| 添加边界情况说明 | 如表面失效、快照过期等 |
| 添加 FAQs | 常见问题快速解答 |

### 5.4 跨 Skill 链接

- `cmux-browser/SKILL.md` 已引用 `../cmux/SKILL.md`
- 建议建立更明确的依赖声明机制

### 5.5 模板质量

- 模板可考虑参数化（接受环境变量）
- 添加 `--help` 或使用说明

---

## 6. 总结

cmux Skills 系统是一个**轻量级但功能完整**的 LLM skill 框架：

**优点**：
- 结构清晰，易于维护
- 文档与代码解耦
- 支持分层参考文档
- 模板可复用

**可改进**：
- 缺少基础设施（注册、版本、测试）
- agents 配置较简单
- 错误处理和边界情况文档不足

整体设计符合"简单优先"原则，适合当前项目规模。如需扩展，可考虑增强 agents 配置和添加基础设施。
