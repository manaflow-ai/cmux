- 2026-11-22 (lane/next-menu-decide): Sidebar-Look: no visual change. Leo, 2026-11-22: "pick a f***ing option" and,
  on Remove from Top, "just move it yourself. you can drag it anywhere you want". Every sidebar menu offers one way to
  do each thing. The + button's right-click and press menu is its own context, `sidebarNew` (`SidebarContextTarget.newButton`): New
  Browser Workspace, New Cloud Workspace, New Workspace on Machine… (the one remote entry), Open Folder…, New Group,
  Reopen Closed Workspace. The sidebar background menu loses rows another menu, a drag or Customize… already offers
  (`pointerMenuTrim`). The item menu keeps Remove from Sidebar only (Remove from Section and Hide App are `duplicateOfDefault`).
  Move Up/Down/To Top/To Bottom, Remove from Top and Move Tab Left/Right leave every menu (`dragGesture`). Dropping an
  app, built-in, link or room beside the sidebar now removes it, as the Chief's drag already did
  (`LayoutItem.comesOffOnDragOut`). Regression: `PointerMenuTrimTests`, catalog `sidebar_customization`.
