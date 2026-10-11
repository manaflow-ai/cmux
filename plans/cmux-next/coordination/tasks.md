# Lane: tasks

## Active streams
- Tasks lead (plans/cmux-next/tasks.md section 14). Rust slices 1-3 and 5 (P8 actor stamp, Replica + epoch fence, `cmux task` in the cmux binary, MCP task tools) wait on branch feat-cmux-next-tasks-s1 for P8 `credential.verify` and a cmux-tui window. JournalReplica (TeamVmDO journal, e4c59605b9e) waits for the team VM bind route.

## Landed
- 2026-10-03 (this push) app: Tasks internal page `tasks` (InternalPageProvider, one shared TasksModel over SocketTasksSource on the local owner socket `~/Library/Application Support/cmux/tasks/<team>/tasks.sock`, CMUX_TASKS_HOME override; empty state names `cmux task serve`, the app starts no process); catalog actions `tasks.show` (CLI `task open`), `tasks.showMine` (CLI `task mine`), `tasks.new` (palette/keyboard, CLI guiOnly; focuses the New Task title field, which sends `task.create`); user setting `tasks.layout` list|board|inbox (default inbox) in Settings and cmux.json; one Assignee control (person = `task.update`, agent = `task.delegate`). One CLI noun `task`: the Rust `cmux task open` / `cmux task mine --open-pane` routing lands with slice 3 (tasks lead)
