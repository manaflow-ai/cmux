/// The toolbar's SF Symbols, shared by the web templates and native button descriptors.
export const HEADER_SYMBOLS: Readonly<Record<string, string>> = {
  "view.list": "list.bullet",
  "diff.file": "plusminus",
  terminal: "terminal",
  browser: "globe",
  "action.more": "ellipsis",
  "action.add": "plus",
  "tunable.sidebar": "sidebar.right",
  folder: "folder",
  "media.play": "play",
  "pane.split.down": "rectangle.split.1x2",
  inbox: "tray",
  "status.info": "info.circle",
  "agent.session": "bubble.left.and.bubble.right",
  "git.worktree": "arrow.triangle.branch",
  "git.pullrequest": "arrow.triangle.pull",
  "action.share": "person.crop.circle.badge.plus",
};

/// Symbols the app draws from the cmux pack, not as SF Symbols (the icon catalog's `overrides`): the outlined globe
/// and the bare >_ prompt (Leo 2026-11-09: "just draw that basketball instead of that busy thing we have on our top
/// right"). The page draws them from its own pack as well.
export const PACK_DRAWN_SYMBOLS: ReadonlySet<string> = new Set(["globe", "terminal"]);
