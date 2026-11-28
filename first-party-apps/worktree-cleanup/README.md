# Auto cleanup (manifest only)

The App Store entry for automatic worktree cleanup. It has no code: its `setting` names the cmux setting its switch drives, `worktrees.autoCleanup` (default on), which acpmux reads before each automatic pass (`cmux-tui/crates/acpmux/src/hub/worktree_care.rs`). Turning the entry off in the App Store writes `false` there; turning it on writes `true`. The listing reads the setting, so an edit of `cmux-next.json` shows in the App Store too. A run on demand is the Storage on This Mac card's Clean up now.
