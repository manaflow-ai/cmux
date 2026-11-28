- 2026-11-14 (lane/ext-sidebar-interface, cmux.sidebar/1, capability matrix row 3): Sidebar-Look: no visual change by default. Leo, verbatim:
  "the sdk's stuff should all be hot reloadable from users' builds... oh yesh you guys needed to research what [two other tools]
  had in terms of capabilities and we need to do better than then" and "3. yeah the whole point is for it to be
  usable". An extension named in `sidebar.workspaceListApp` (empty by default) draws in the workspace list's frame
  (`SidebarListSwap`, from `SidebarAppSectionProvider.workspaceList`); the built-in list stays the default and draws
  whenever the extension is not drawn (none chosen, removed, loading, failing, safe mode). Bands, footer and cards stay
  native. Regression: `SidebarListReplacementTests`.
