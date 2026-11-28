- 2026-11-18 (sidebar-threads-by-project, CMUX-642): Sidebar-Look: Leo: "make customization for codex, t3code, claude code
  app (everything)", "sidebar, gui, everything". A new setting, `sidebar.relativeTimestamps` (off by default), makes a
  row's timestamp (`sidebar.showTimestamps`) read today's change as its age (`1m` at least, `5m`, `2h`) instead of its
  time; a day or more reads in days as before. Rows count from the current minute (`SidebarLayoutOptions.now` is that
  minute only while the setting is on; otherwise the start of today, as before). A quiet list reloads once as a label
  turns (`SidebarRelativeTimesTick`: one `DemandTimer` per list, armed only while relative times show). With
  `sidebar.groupBy` folder and `sidebar.workspaceRow.branch` it gives chats under their project folders with an age and
  a branch line. Off, nothing draws differently. Tests: `SidebarThreadsLookTests`, `SidebarRelativeTimestampsSettingTests`;
  gallery variant `threads` in `AASidebarCustomizationGalleryTests`.
