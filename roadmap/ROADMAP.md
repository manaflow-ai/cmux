# cmux Linux MVP — TDD Implementation Roadmap

Each commit is 100–500 delta lines. Tests written first (red), then
implementation (green). Ordered by dependency.

Two-crate structure: `cmux-core` (platform-agnostic) and `cmux-gtk` (GTK4 UI).
Core tests run anywhere; GTK tests need `xvfb-run`.

---

## Phase 1: Project Skeleton + Core Data Model (Commits 1–5)

### Commit 1: Workspace + crate scaffold
**Delta: ~200 lines**

Files:
- `Cargo.toml` (workspace with `crates/cmux-core`, `crates/cmux-gtk`)
- `crates/cmux-core/Cargo.toml` (serde, serde_json, uuid, toml)
- `crates/cmux-core/src/lib.rs` (module declarations)
- `crates/cmux-gtk/Cargo.toml` (gtk4, cmux-core)
- `crates/cmux-gtk/src/main.rs` (empty GtkApplication, blank window)
- `.github/workflows/ci.yml` (cargo build + cargo test)
- `README.md`

Tests:
- `cmux-core`: lib compiles
- `cmux-gtk`: app creates without panic (headless)

### Commit 2: Split tree data model + tests
**Delta: ~300 lines**

Files:
- `crates/cmux-core/src/split_tree.rs`

Types: `PaneId(Uuid)`, `Direction { Horizontal, Vertical }`, `SplitNode`

Operations:
- `SplitNode::new_leaf(pane_id)` — create leaf
- `SplitNode::split(target_pane, direction, new_pane)` — split a leaf into two
- `SplitNode::remove(pane_id)` — remove pane, collapse parent
- `SplitNode::find(pane_id) -> bool`
- `SplitNode::pane_ids() -> Vec<PaneId>` — collect all leaves

Tests (TDD, write first):
- Create leaf, verify it's a leaf with correct id
- Split leaf, verify tree has Split with two Leaf children
- Remove one child of split, verify collapse back to single leaf
- Split nested: split a leaf that's already inside a split
- Find existing pane -> true, missing pane -> false
- pane_ids returns all leaves in order

### Commit 3: Split tree navigation + tests
**Delta: ~250 lines**

Files:
- `crates/cmux-core/src/split_nav.rs`

Function: `navigate(tree: &SplitNode, from: PaneId, dir: Direction) -> Option<PaneId>`

Algorithm: find `from` in tree, walk up to find a split in matching direction,
then walk down the opposite branch to find nearest leaf.

Tests:
- H-split [A, B]: navigate right from A -> B
- H-split [A, B]: navigate left from B -> A
- H-split [A, B]: navigate up from A -> None
- V-split [A, B]: navigate down from A -> B
- Nested: H-split [V-split[A,B], C]: navigate right from A -> C
- Nested: navigate down from A -> B (within same v-split)
- Single leaf: any direction -> None

### Commit 4: Split tree serialization + tests
**Delta: ~200 lines**

Files:
- Update `crates/cmux-core/src/split_tree.rs` with `#[derive(Serialize, Deserialize)]`

Serde config: use `#[serde(tag = "type")]` for SplitNode enum to produce
clean JSON (`{"type": "leaf", "pane_id": "..."}` / `{"type": "split", ...}`).

Tests:
- Serialize single leaf -> JSON string -> deserialize -> equal
- Serialize 3-pane tree -> JSON -> deserialize -> structurally equal
- Deserialize invalid JSON -> Err
- Deserialize JSON with missing fields -> Err
- Round-trip preserves all fields (direction, ratio, pane_ids)

### Commit 5: Tab + Workspace model + tests
**Delta: ~350 lines**

Files:
- `crates/cmux-core/src/tab.rs`
- `crates/cmux-core/src/workspace.rs`

Tab: `{ id: TabId, title: String, split_tree: SplitNode, has_notification: bool, order: usize }`
Workspace: `{ tabs: Vec<Tab>, active_tab: TabId, focused_pane: PaneId }`

Workspace operations:
- `add_tab() -> TabId` — append new tab with single pane
- `close_tab(id)` — remove tab, select neighbor (prev, or next, or None)
- `reorder_tab(from_idx, to_idx)` — move tab, update all order fields
- `rename_tab(id, title)`
- `set_active_tab(id)` / `active_tab() -> &Tab`
- `set_focused_pane(id)` / `focused_pane() -> PaneId`

Tests:
- New workspace has 0 tabs
- add_tab: count goes to 1, active_tab set
- add 3 tabs: count is 3, orders are 0,1,2
- close middle tab: count is 2, active moves to neighbor
- close last remaining tab: active_tab is None (or error)
- reorder [A,B,C] move A to idx 2: order is [B,C,A]
- rename updates title; rename to empty reverts to default

---

## Phase 2: Session Persistence (Commits 6–7)

### Commit 6: Session data model + serialization tests
**Delta: ~250 lines**

Files:
- `crates/cmux-core/src/session.rs`

Types:
- `SessionData { version: u32, tabs: Vec<TabData>, active_tab: TabId }`
- `TabData { id, title, order, split_tree: SplitNodeData }`
- `SplitNodeData` — like SplitNode but with `cwd: PathBuf` instead of PaneId

Functions:
- `SessionData::from_workspace(ws, cwd_lookup: impl Fn(PaneId) -> PathBuf)`
- `SessionData::to_json() -> String`
- `SessionData::from_json(s: &str) -> Result<Self>`

Tests:
- Round-trip empty workspace (0 tabs)
- Round-trip 3 tabs with splits, verify all fields preserved
- from_json with corrupt data -> Err
- from_json with wrong version -> Err
- Tab order preserved through round-trip

### Commit 7: Session file I/O
**Delta: ~200 lines**

Files:
- `crates/cmux-core/src/session_file.rs`

Functions:
- `save(data: &SessionData, path: &Path)` — atomic write (tmp + rename)
- `load(path: &Path) -> Result<Option<SessionData>>` — None if missing

Uses `xdg` crate: default path is `$XDG_STATE_HOME/cmux/session.json`
(typically `~/.local/state/cmux/session.json`).

Tests:
- Save + load round-trip in tempdir
- Load from nonexistent file -> Ok(None)
- Save creates parent dirs if missing
- Concurrent save doesn't corrupt (atomic rename)

---

## Phase 3: GTK Window + Sidebar (Commits 8–12)

### Commit 8: Main window layout
**Delta: ~250 lines**

Files:
- `crates/cmux-gtk/src/window.rs`

`CmuxWindow` — custom GtkApplicationWindow subclass (via `glib::wrapper!`):
- Horizontal GtkPaned: left sidebar (GtkBox, 200px min-width) + right content (GtkStack)
- Sidebar resizable via paned divider
- Header bar with app title
- Wire up in `main.rs`

Test: window creates, sidebar and content area exist (headless)

### Commit 9: Tab sidebar — static list rendering
**Delta: ~350 lines**

Files:
- `crates/cmux-gtk/src/sidebar.rs`
- `crates/cmux-gtk/src/tab_row.rs`

Sidebar: GtkListBox inside GtkScrolledWindow
TabRow: GtkBox containing GtkLabel (title) + GtkImage (notification dot, hidden by default)

Wire to Workspace model:
- On workspace change -> rebuild list
- Click row -> `workspace.set_active_tab(id)` -> switch content stack page
- Active tab row gets `.active` CSS class

Test: create workspace with 3 tabs, verify 3 rows rendered, click second row
changes active

### Commit 10: Add/close tab actions
**Delta: ~200 lines**

Files:
- Update `sidebar.rs` — "+" button at sidebar bottom
- Update `tab_row.rs` — "x" button visible on hover
- `crates/cmux-gtk/src/keybinds.rs` — action map setup

Actions:
- `tab.new` (Ctrl+Shift+T) -> workspace.add_tab()
- `tab.close` (Ctrl+Shift+W) -> workspace.close_tab(active)

Test: click "+", verify tab count +1; click "x", verify tab removed

### Commit 11: Tab rename
**Delta: ~250 lines**

Files:
- Update `tab_row.rs`

Trigger: double-click label OR F2 keybind
Behavior: replace GtkLabel with GtkEntry, prefilled with current title
- Enter: commit rename, swap back to label
- Escape: cancel, swap back to label
- Empty submit: revert to default name ("Terminal N")

Tests:
- Rename to "foo" -> tab title is "foo"
- Cancel preserves original
- Empty rename -> default name

### Commit 12: Tab drag-to-reorder
**Delta: ~300 lines**

Files:
- `crates/cmux-gtk/src/tab_drag.rs`
- Update `sidebar.rs`

GTK4 DragSource on each TabRow, DropTarget on sidebar ListBox.
Content type: custom `GdkContentProvider` carrying `TabId`.
On drop: `workspace.reorder_tab(from_idx, to_idx)`, rebuild sidebar.
Visual: highlight drop position with CSS class during drag.

Tests:
- Drag tab 0 to position 2: order becomes [1,2,0]
- Drag to same position: no change
- Drag only tab: no-op

---

## Phase 4: Terminal Integration (Commits 13–16)

### Commit 13: Ghostty FFI bindings
**Delta: ~250 lines**

Files:
- `build.rs` — use `bindgen` to generate bindings from `ghostty.h`
- `crates/cmux-gtk/src/ghostty_ffi.rs` — safe wrapper types

Link strategy: `pkg-config` for system libghostty, fallback to `GHOSTTY_LIB_DIR` env var.

Key FFI functions to wrap:
- `ghostty_init()` / `ghostty_deinit()`
- `ghostty_surface_new(config)` -> surface handle
- `ghostty_surface_free(handle)`
- `ghostty_surface_get_widget(handle)` -> GtkWidget pointer
- `ghostty_surface_set_size(handle, w, h)`

Fallback plan: if Ghostty FFI proves too complex, swap to VTE
(`libvte-2.91-gtk4`). The `Terminal` trait in cmux-core abstracts this.

Test: init + deinit without crash; create surface, verify non-null widget

### Commit 14: Terminal widget wrapper
**Delta: ~400 lines**

Files:
- `crates/cmux-gtk/src/terminal.rs`

`TerminalWidget` struct:
- Wraps Ghostty surface (or VTE widget as fallback)
- `new(cwd: &Path) -> Self` — create surface, spawn shell
- `widget() -> &gtk4::Widget` — for embedding in containers
- `pid() -> u32` — shell process ID
- `on_exit(callback)` — register shell exit handler
- `on_title_change(callback)` — register title change handler
- Implements `Drop` to free surface + kill shell

Shell spawn: `$SHELL` env var, fallback `/bin/bash`, in given cwd.

Tests:
- Create terminal, verify pid > 0
- Create terminal with cwd, verify `/proc/<pid>/cwd` matches
- Terminal widget is non-null GtkWidget

### Commit 15: Terminal lifecycle + events
**Delta: ~300 lines**

Files:
- Update `terminal.rs`

Event handling:
- Shell exit: detect via `SIGCHLD` / `waitpid`, fire `on_exit` callback
- Title change: Ghostty callback -> fire `on_title_change`
- Close: `terminal.close()` sends SIGHUP to shell process group, frees surface

Pty cleanup: close fd on terminal close to prevent zombie ptys.

Tests:
- Spawn shell, send `exit\n`, verify on_exit fires
- Close terminal, verify child process is gone
- Title change callback fires when shell sets title

### Commit 16: Wire terminals into tab content
**Delta: ~400 lines**

Files:
- Update `window.rs`, `sidebar.rs`

Content area: GtkStack with one page per tab.
Each tab page contains the split_view widget tree (initially single terminal).

On tab switch:
- Hide old tab's widget tree
- Show new tab's widget tree
- Focus the active pane's terminal

On new tab:
- Create TerminalWidget with cwd = $HOME
- Add to content stack
- Focus it

On close tab:
- Destroy all terminals in tab's split tree
- Remove stack page

Test: create 2 tabs, switch between them, verify correct terminal shown

---

## Phase 5: Split Pane UI (Commits 17–20)

### Commit 17: Render split tree as GTK widget tree
**Delta: ~400 lines**

Files:
- `crates/cmux-gtk/src/split_view.rs`

Recursive builder: `build_widget(node: &SplitNode, terminals: &HashMap<PaneId, TerminalWidget>) -> gtk4::Widget`
- Leaf -> terminal.widget()
- Split -> GtkPaned(orientation, first_child, second_child) with ratio set

Rebuild: on split/close, destroy old widget tree and rebuild from model.
(Optimization: incremental updates can come later, full rebuild is fine for MVP.)

Test: build from 3-pane tree [H-split: [A, V-split: [B, C]]], verify
GtkPaned nesting is correct

### Commit 18: Split + close pane actions
**Delta: ~350 lines**

Files:
- Update `keybinds.rs`, `split_view.rs`

Actions:
- `pane.split_h` (Ctrl+Shift+H) -> split focused pane horizontally
- `pane.split_v` (Ctrl+Shift+V) -> split focused pane vertically
- `pane.close` (Ctrl+Shift+X) -> close focused pane

Split: create new TerminalWidget with same cwd as focused pane, insert into
split tree, rebuild widget tree.

Close: destroy terminal, remove from split tree, rebuild. If last pane in
tab, close the tab.

Tests:
- Split pane: tree now has 2 leaves
- New pane cwd matches original
- Close pane: tree collapses back
- Close last pane: tab is closed

### Commit 19: Pane focus + keyboard navigation
**Delta: ~300 lines**

Files:
- Update `split_view.rs`, `keybinds.rs`

Focus tracking:
- Click terminal -> `workspace.set_focused_pane(id)`
- Focused pane gets `.focused` CSS class (visible border)
- Ctrl+Alt+Arrow -> `split_nav::navigate()` -> focus result pane

On focus change: call `terminal.widget().grab_focus()` on the target.

Tests:
- Click pane B in [A, B] split: focused_pane is B
- Ctrl+Alt+Right from A: focus moves to B
- Focus indicator CSS class toggles correctly

### Commit 20: Pane resize
**Delta: ~150 lines**

Files:
- Update `split_view.rs`

GtkPaned handles mouse drag natively. On `notify::position` signal,
update `SplitNode.ratio` in the model to keep it in sync.

Keyboard resize: Ctrl+Shift+Arrow -> adjust ratio by 0.05 increment.

Test: resize pane, verify model ratio updated

---

## Phase 6: Notifications (Commits 21–23)

### Commit 21: Notification state machine + tests
**Delta: ~250 lines**

Files:
- `crates/cmux-core/src/notification.rs`

`NotificationState` enum: `Idle`, `Busy`, `Notified`

`NotificationTracker`:
- `on_child_spawned(pane_id)` -> state = Busy
- `on_child_exited(pane_id, is_focused: bool)` -> Notified (or Idle if focused)
- `on_pane_focused(pane_id)` -> Idle, returns true if was Notified
- `state(pane_id) -> NotificationState`

Tests (all pure logic, no GTK):
- Initial state is Idle
- Idle -> on_child_spawned -> Busy
- Busy -> on_child_exited(not focused) -> Notified
- Busy -> on_child_exited(focused) -> Idle (no notification)
- Notified -> on_pane_focused -> Idle, returns true
- Idle -> on_pane_focused -> Idle, returns false
- Multiple panes tracked independently

### Commit 22: Process monitoring
**Delta: ~300 lines**

Files:
- `crates/cmux-gtk/src/process_monitor.rs`

Monitor foreground process of each pane's pty:
- Poll `/proc/<shell_pid>/stat` field 8 (tpgid) at 500ms interval via `glib::timeout_add`
- When tpgid != shell_pid: child is running -> on_child_spawned
- When tpgid == shell_pid after being != : child exited -> on_child_exited
- Feed transitions into NotificationTracker

Wire to workspace: when Notified, set `tab.has_notification = true`.
When pane focused, clear notification.

Tests:
- Run `sleep 0.2` in terminal, wait, verify notification fires
- Focus pane after notification, verify cleared
- Rapidly spawning/exiting children doesn't cause spurious notifications

### Commit 23: Notification ring CSS
**Delta: ~200 lines**

Files:
- Update `crates/cmux-gtk/src/style.css`
- Update `tab_row.rs`

CSS animation:
```css
.tab-row.notified {
    animation: notification-ring 2s ease-in-out infinite;
}
@keyframes notification-ring {
    0%, 100% { border-color: rgba(59, 130, 246, 0.3); }
    50% { border-color: rgba(59, 130, 246, 0.9); }
}
```

TabRow: toggle `.notified` class when `tab.has_notification` changes.
Notification dot (small circle) also becomes visible.

Test: set notification on tab, verify `.notified` CSS class present;
clear notification, verify class removed

---

## Phase 7: Session Restore + Config (Commits 24–27)

### Commit 24: Save session on quit
**Delta: ~250 lines**

Files:
- Update `crates/cmux-gtk/src/main.rs`

Hook `GtkApplication::shutdown`:
1. Collect cwd for each pane via `/proc/<pid>/cwd` readlink
2. Build `SessionData::from_workspace(ws, cwd_lookup)`
3. `session_file::save()` to XDG state dir

Test: create workspace with 2 tabs + split, trigger shutdown, verify
session.json written with correct structure

### Commit 25: Restore session on launch
**Delta: ~300 lines**

Files:
- Update `crates/cmux-gtk/src/main.rs`, `window.rs`

On `GtkApplication::activate`:
1. `session_file::load()` — if None, create default workspace (1 tab, 1 pane)
2. If Some: rebuild tabs, split trees, spawn terminals with saved cwds
3. Set active tab, attempt to focus saved pane
4. Delete session file after successful restore (prevent stale restore on crash)

Test: save session with 3 tabs + splits, relaunch, verify tab count,
titles, and split structure match

### Commit 26: Config file + keybind overrides
**Delta: ~250 lines**

Files:
- `crates/cmux-core/src/config.rs`

Config file: `$XDG_CONFIG_HOME/cmux/config.toml`

```toml
[keybinds]
"tab.new" = "Ctrl+T"
"pane.split_h" = "Ctrl+D"

[appearance]
sidebar_width = 250
```

Parser: read file, merge with defaults, return `Config` struct.
Keybind overrides applied at action-map registration time.

Tests:
- Parse valid config
- Missing file -> defaults
- Invalid keybind string -> skip with warning
- Override one keybind, others keep defaults

### Commit 27: Polish — context menu, sidebar toggle, error handling
**Delta: ~350 lines**

Files:
- Update `style.css`, `sidebar.rs`, `tab_row.rs`, `keybinds.rs`

Features:
- Toggle sidebar: Ctrl+Shift+B (show/hide sidebar pane)
- Tab context menu (right-click): Rename, Close, Duplicate
- Duplicate tab: new tab with same split structure + cwds
- Graceful error handling: terminal spawn failure -> show error in pane area
- Style finalization: colors, borders, spacing, scrollbar

Test: toggle sidebar, verify hidden/shown; right-click menu items work

---

## Summary

| Phase | Commits | Delta Lines | Running Total |
|---|---|---|---|
| 1. Skeleton + Core Model | 1–5 | ~1,300 | ~1,300 |
| 2. Session Persistence | 6–7 | ~450 | ~1,750 |
| 3. GTK Window + Sidebar | 8–12 | ~1,350 | ~3,100 |
| 4. Terminal Integration | 13–16 | ~1,350 | ~4,450 |
| 5. Split Pane UI | 17–20 | ~1,200 | ~5,650 |
| 6. Notifications | 21–23 | ~750 | ~6,400 |
| 7. Session Restore + Config | 24–27 | ~1,150 | ~7,550 |
| **Total** | **27 commits** | | **~7,500–9,000** |

## Dependency Graph

```
Phase 1 (core data model)
  ├─> Phase 2 (session model)  ── can parallel ──┐
  └─> Phase 3 (sidebar UI)                       │
        └─> Phase 4 (terminal integration)       │
              ├─> Phase 5 (split UI)             │
              └─> Phase 6 (notifications)         │
                    └─> Phase 7 (restore + polish) ◄┘
```

Phases 2 and 3 can run in parallel after Phase 1.
Phases 5 and 6 can run in parallel after Phase 4.
