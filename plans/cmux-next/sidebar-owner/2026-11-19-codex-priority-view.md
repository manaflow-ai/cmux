- 2026-11-19 (lane/codex-priority-view): Sidebar-Look: Leo, 2026-11-19: "how about the customizations for
  claude/codex/[...] aka \"studio\" and the actual functionality and features of them?". The Priority view can act as
  the Codex app's activity list, behind three settings whose defaults draw today's view:
  `sidebar.priorityView.filters` (All, Waiting, Unread and Running chips with counts under the header, and Mark All as
  Read in the header's trailing slot; the pick is a Priority mark), `sidebar.priorityView.showIdle` (off: idle rows
  leave, a pinned or dragged one stays) and `sidebar.priorityView.statusWords` (each row's chip says its state: "Needs
  you", "Done", "Working 5m"). Row heights are unchanged; the chips add one line to the panel's top. Regression:
  `SidebarPriorityFiltersTests`; gallery `AACodexPriorityGalleryTests.renderTheCodexPriorityView`.
