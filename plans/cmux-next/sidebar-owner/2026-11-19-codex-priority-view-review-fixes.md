- 2026-11-19 (lane/codex-priority-view, review fixes): Sidebar-Look: a keyboard focus ring on the Priority filter
  chips, the sidebar buttons' own (`Palette.focusRing`, 1.5 pt, only with keyboard access on and the window key).
  With Keyboard Navigation on, Tab focuses a chip, Space or Return picks it and the arrow keys pick the chip beside
  (wrapping); the bar is a radio group. A drag under a filter now keeps every shown row's new slot, so hidden rows
  keep theirs. The five `sidebar.priorityView.*` settings rows have their own "Priority View" card. Regression:
  `SidebarPriorityFilterChipKeysTests`, `SidebarPriorityFiltersTests.aDragUnderAFilterGivesTheMergedFeedOrder`.
