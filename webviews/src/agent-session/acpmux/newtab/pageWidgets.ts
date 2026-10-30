// The Minimal layout's widgets (Leo 2026-10-20: "only do the composer for the default"): the page
// is the composer; everything else it can show is a widget the user turns on in Settings (`tabs.newTabWidgets.*`, NewTabWidgetSettings.swift), which the host sends as the
// handshake's `pageWidgets`. The other layouts (the page's dots, templates.ts) draw what they always
// drew: they are there to compare against.

/// Every widget, in Settings' order.
export const PAGE_WIDGETS = [
  "greeting",
  "projects",
  "actions",
  "chats",
  "styleDots",
  "weather",
  "machines",
  "clock",
  "timer",
  "warmGreeting",
  "quote",
] as const;
export type PageWidget = (typeof PAGE_WIDGETS)[number];
export type PageWidgets = ReadonlySet<PageWidget>;

/// "greeting" is the headline over the composer (NewTabHeadline.tsx: "What should we work on in
/// <project>?"), off by default (Leo 2026-10-22: "new tab page let's have no greeting text by
/// default... maybe as toggle but as useful toggle"). It keeps the setting's old name
/// (`tabs.newTabWidgets.greeting`), so a saved `true` turns the headline on; there is no
/// time-of-day greeting any more.

/// The widgets the page's edit mode moves (`tabs.newTabWidgets.order`, NewTabWidgetEdits.swift),
/// in Settings' order. The headline stays over the composer; the dots stay put.
export const MOVABLE_WIDGETS = ["projects", "actions", "chats"] as const;
export type MovableWidget = (typeof MOVABLE_WIDGETS)[number];

/// What Minimal shows when the host sends no list (Settings' defaults): nothing but the composer.
const MINIMAL_DEFAULT_LIST: readonly PageWidget[] = [];
const MINIMAL_DEFAULT: PageWidgets = new Set<PageWidget>(MINIMAL_DEFAULT_LIST);
/// The ambient widgets (newtab/ambient.ts): every layout shows them when the user turns them on.
/// They keep their own row under the composer, so the edit mode does not move them.
const AMBIENT: ReadonlySet<PageWidget> = new Set<PageWidget>(["weather", "machines"]);
/// What every other layout shows: everything it drew before the widgets, with no headline.
const OTHER_LAYOUTS: readonly PageWidget[] = PAGE_WIDGETS.filter(
  (widget) =>
    widget !== "greeting" && !AMBIENT.has(widget) && !["clock", "timer", "warmGreeting", "quote"].includes(widget),
);

/// The widgets a handshake's `pageWidgets` names, in PAGE_WIDGETS' places, the movable ones in the
/// list's order (the host sends them in the user's, `tabs.newTabWidgets.order`); undefined when it
/// sends none (not an array). Unknown names are dropped.
export function parsePageWidgets(value: unknown): PageWidget[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const order = [...new Set(value)].filter(isMovable);
  let next = 0;
  return PAGE_WIDGETS.filter((widget) => value.includes(widget)).map((widget) =>
    isMovable(widget) ? (order[next++] ?? widget) : widget,
  );
}

function isMovable(widget: unknown): widget is MovableWidget {
  return MOVABLE_WIDGETS.includes(widget as MovableWidget);
}

/// The movable widgets on, in the order the page shows them.
export function shownMovable(widgets: PageWidgets): MovableWidget[] {
  return [...widgets].filter(isMovable);
}

/// What the page's edit mode or its dots did (`newTab.editWidgets`; the host writes it as Settings
/// would). `show` turns a widget on (the second dot's quick actions, tabDots.ts).
export type WidgetEdit =
  | { edit: "remove"; widget: PageWidget }
  | { edit: "show"; widget: PageWidget }
  | { edit: "order"; order: MovableWidget[] }
  | { edit: "add" };

/// The page's widget list after `edit`: a removed one goes; a shown one joins in its place; a new
/// order moves the movable ones and keeps the others where they are. `+` changes nothing here (the
/// App Store turns one on).
export function editedPageWidgets(widgets: readonly PageWidget[] | undefined, edit: WidgetEdit): PageWidget[] {
  const list = widgets ?? MINIMAL_DEFAULT_LIST;
  if (edit.edit === "remove") return list.filter((widget) => widget !== edit.widget);
  if (edit.edit === "show") return list.includes(edit.widget) ? [...list] : parsePageWidgets([...list, edit.widget])!;
  if (edit.edit === "add") return [...list];
  const moved = edit.order.filter((widget) => list.includes(widget));
  let next = 0;
  return list.map((widget) => (isMovable(widget) ? (moved[next++] ?? widget) : widget));
}

/// The page's handshake with an edit shown in place, on any style. `pageWidgets` is always Minimal's
/// list (`tabs.newTabWidgets.*`; the host's, else Settings' defaults), so a dot's pick on Default or
/// Cards edits only that widget of Minimal's and the style on screen keeps all it draws
/// (shownPageWidgets).
export function withWidgetEdit<Page extends { pageWidgets?: PageWidget[] }>(page: Page, edit: WidgetEdit): Page {
  return { ...page, pageWidgets: editedPageWidgets(page.pageWidgets, edit) };
}

/// `order` with `widget` moved `by` places (-1 earlier, 1 later), clamped to the list.
export function movedWidget(order: readonly MovableWidget[], widget: MovableWidget, by: number): MovableWidget[] {
  const from = order.indexOf(widget);
  if (from < 0) return [...order];
  const to = Math.max(0, Math.min(order.length - 1, from + by));
  const next = order.filter((item) => item !== widget);
  next.splice(to, 0, widget);
  return next;
}

/// `order` with `widget` dropped before `target` (or after it, `after`).
export function droppedWidget(
  order: readonly MovableWidget[],
  widget: MovableWidget,
  target: MovableWidget,
  after: boolean,
): MovableWidget[] {
  if (widget === target) return [...order];
  const next = order.filter((item) => item !== widget);
  next.splice(next.indexOf(target) + (after ? 1 : 0), 0, widget);
  return next;
}

/// The widgets a page in `template` shows: the user's on Minimal, the layout's own on the others
/// (with the ambient ones the user turned on).
export function shownPageWidgets(template: string, widgets?: readonly PageWidget[]): PageWidgets {
  if (template !== "minimal")
    return new Set([...OTHER_LAYOUTS, ...(widgets ?? []).filter((widget) => AMBIENT.has(widget))]);
  return widgets ? new Set(widgets) : MINIMAL_DEFAULT;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// An edit made on the page: saved by the host (`newTab.editWidgets`), and shown in place at once.
export function editNewTabWidgets(edit: WidgetEdit, deps: { callNative: Native; show(edit: WidgetEdit): void }): void {
  void deps.callNative("newTab.editWidgets", edit).catch(() => undefined);
  deps.show(edit);
}
