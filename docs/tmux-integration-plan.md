# cmux tmux Control Mode Integration Plan

## Background

cmux 在 tmux 下所有依賴「讀 Ghostty viewport 文字」的功能都失效：
- cmd+click link detection
- 左側 tree notification
- CJK IME cursor 定位

**根因**：tmux 用自己的 screen buffer 渲染到 host terminal。Ghostty 的 `render_state.string()` 在 tmux 下回傳幾乎全是 null bytes，看不到 pane 內容。

## 關鍵發現

Ghostty 已有完整的 tmux control mode 實作（build flag `tmux_control_mode`，預設開啟）：

| 檔案 | 行數 | 功能 |
|------|------|------|
| `src/terminal/tmux/control.zig` | 725 | tmux control mode protocol parser |
| `src/terminal/tmux/viewer.zig` | 2292 | tmux pane viewer + state machine |
| `src/terminal/tmux/layout.zig` | 638 | layout parser |
| `src/terminal/tmux/output.zig` | 590 | output handler |

- 作者是 Mitchell Hashimoto（Ghostty 原作者），2025-12 寫的上游原生功能
- 每個 tmux Pane 裡已有一個 `Terminal` 實例，維護完整的 terminal state
- `Viewer.Action` 有三種：`exit`、`command`、`windows`

## 缺失的接線

`src/termio/stream_handler.zig` L427-449：

```zig
for (viewer.next(.{ .tmux = tmux })) |action| {
    switch (action) {
        .exit => { /* ignored, handled by DCS end */ },
        .command => |cmd| { /* sends command to tmux */ },
        .windows => { /* TODO */ },  // ← 這裡是空的
    }
}
```

- `exit` 和 `command` 已有 handler
- `windows`（pane topology 變更）是 **TODO**
- **沒有** tmux actions 暴露到 `ghostty.h` C API
- cmux Swift 層完全看不到 tmux 狀態

## Phase 1：最小 tmux bridge（read-only）

**目標**：讓 cmux 拿到 tmux pane 的文字內容，證明 link detection 可以在結構化資料上運作。

### Ghostty Zig 層

1. 在 action system 新增 tmux events：
   - `tmux_enter` / `tmux_exit`：lifecycle
   - `tmux_windows_changed`：topology 變更，帶 window/pane list
   - `tmux_pane_output`：某 pane 有新輸出（by pane_id）

2. 在 `ghostty.h` 暴露：
   - `ghostty_action_tmux_*` structs
   - `ghostty_surface_tmux_pane_text(surface, pane_id, text*)` 查詢 API

3. 在 `stream_handler.zig` 的 `.windows` TODO 裡 fire action

### cmux Swift 層

1. 接收 `GHOSTTY_ACTION_TMUX_*` events
2. 在 debug log 裡證明：tmux pane 裡的檔案路徑可以被穩定讀出
3. 用 pane text 做 link detection（取代 render state scraping）

### 不做（留給 Phase 2）

- pane-to-surface 映射
- input routing
- active pane focus sync
- resize propagation
- mouse forwarding

### Demo 標準

在 cmux 的 tmux session 裡：
1. `echo /Users/timfeng/GitHub/genesis/GENESIS.md`
2. cmd+click → 右側開 markdown panel

## Phase 2：完整 tmux integration

**目標**：cmux 成為 tmux 的 first-class GUI（like iTerm2 `tmux -CC`）。

- 每個 tmux pane 對應一個 native Ghostty surface
- 用戶輸入反向送回 tmux
- Layout 雙向同步
- 左側 tree 顯示 tmux sessions/windows/panes
- Notification ring 對每個 pane 獨立運作

### 參考

- [iTerm2 tmux integration architecture](https://deepwiki.com/gnachman/iTerm2/5.2-tmux-integration)：TmuxGateway + TmuxController + TmuxWindowOpener，~4000-6000 行
- [tmux Control Mode protocol](https://github.com/tmux/tmux/wiki/Control-Mode)
- cmux issue [#560](https://github.com/manaflow-ai/cmux/issues/560)

## 相關 Issues / PRs

- PR [#1517](https://github.com/manaflow-ai/cmux/pull/1517)：cmd+click 開檔案（非 tmux 下可用）
- Issue [#1521](https://github.com/manaflow-ai/cmux/issues/1521)：CJK IME cursor 不可見
- Issue [#458](https://github.com/manaflow-ai/cmux/issues/458)：tmux 下 notification 不 work
- Issue [#833](https://github.com/manaflow-ai/cmux/issues/833)：SSH+tmux notification

## 檔案位置

- Ghostty tmux module：`ghostty/src/terminal/tmux/`
- Stream handler（接線點）：`ghostty/src/termio/stream_handler.zig` L385-450
- Ghostty C API：`ghostty/include/ghostty.h`
- cmux action handler：`Sources/GhosttyTerminalView.swift` L1922+
