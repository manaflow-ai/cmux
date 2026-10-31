// State snapshots for agent evals (plans/cmux-next/agent-evals-DESIGN.md).
// `capture` reads a session through the cmux CLI; `normalize` turns the raw
// CLI output into the model the graders read. `normalize` is pure.

/**
 * Places every pane of a layout node on a horizontal column grid.
 * A horizontal split puts `second` right of `first`; a vertical split stacks
 * them in the same columns; a viewport lays its columns out left to right.
 */
function place(node, start, docked, out) {
  if (!node || typeof node !== "object") return 0;
  if (node.kind === "leaf") {
    out.push({ pane_id: node.pane_id, index: start, docked, column_id: null });
    return 1;
  }
  if (node.kind === "split") {
    if (node.direction === "horizontal") {
      const a = place(node.first, start, docked, out);
      return a + place(node.second, start + a, docked, out);
    }
    return Math.max(place(node.first, start, docked, out), place(node.second, start, docked, out));
  }
  if (node.kind === "viewport") {
    let at = start;
    for (const column of node.columns ?? []) {
      const before = out.length;
      const width = place(column.root, at, docked || !!column.dock, out);
      for (const p of out.slice(before)) p.column_id ??= column.column_id;
      at += width;
    }
    return at - start;
  }
  return 0;
}

/** Columns of a screen layout, left to right: [{ column_id, index, docked, pane_ids }]. */
export function columnsOf(layout) {
  if (!layout?.root) return [];
  const placed = [];
  const width = place(layout.root, 0, false, placed);
  return Array.from({ length: width }, (_, index) => {
    const here = placed.filter((p) => p.index === index);
    return {
      column_id: here[0]?.column_id ?? null,
      index,
      docked: here.length > 0 && here.every((p) => p.docked),
      pane_ids: here.map((p) => p.pane_id),
    };
  });
}

export function normalize(raw) {
  const placements = new Map((raw.placements ?? []).map((p) => [p.workspace?.workspace_id, p.group_id ?? null]));
  // The sidebar's order is the personal placement order (PersonalSidebar.swift), not the
  // session's workspace index: `workspace_place {index}` changes only the former.
  const sidebarIndex = new Map((raw.placements ?? []).map((p) => [p.workspace?.workspace_id, p.index]));
  const workspaces = (raw.workspaces ?? []).map((w) => ({
    id: w.id,
    name: w.name ?? "",
    focused: !!w.focused,
    index: w.index,
    sidebar_index: sidebarIndex.get(w.id) ?? w.index,
    group_id: placements.get(w.id) ?? null,
  }));
  const paneInfo = new Map();
  const screens = (raw.screens ?? []).map((s) => {
    const layout = raw.layouts?.[s.id];
    const columns = columnsOf(layout);
    for (const column of columns) {
      for (const pane of column.pane_ids) {
        // `row_index`: top to bottom in its column (a down split puts the new pane after).
        if (!paneInfo.has(pane)) paneInfo.set(pane, { column_index: column.index, row_index: column.pane_ids.indexOf(pane), column_id: column.column_id, docked: column.docked });
      }
    }
    return {
      id: s.id,
      workspace_id: s.workspace_id,
      focused: !!s.focused,
      active_pane_id: layout?.active_pane_id ?? null,
      column_count: columns.length,
      columns,
    };
  });
  const screenOf = new Map(screens.map((s) => [s.id, s]));
  const panes = (raw.panes ?? []).map((p) => ({
    id: p.id,
    screen_id: p.screen_id,
    workspace_id: screenOf.get(p.screen_id)?.workspace_id ?? null,
    column_index: paneInfo.get(p.id)?.column_index ?? 0,
    row_index: paneInfo.get(p.id)?.row_index ?? 0,
    column_id: paneInfo.get(p.id)?.column_id ?? null,
    docked: paneInfo.get(p.id)?.docked ?? false,
  }));
  const terminals = new Map((raw.terminals ?? []).map((t) => [t.id, t]));
  const tabs = (raw.tabs ?? []).map((t) => {
    const terminal = terminals.get(t.content_id);
    return {
      id: t.id,
      pane_id: t.pane_id,
      kind: t.content_kind ?? "unknown",
      content_id: t.content_id ?? null,
      name: t.name ?? null,
      label: t.name || terminal?.title || "",
      url: t.url ?? t.extra?.url ?? null,
      index: t.index,
    };
  });
  const tabGroupOf = new Map();
  const tabGroups = (raw.tabGroups ?? []).map((g) => {
    for (const id of g.tab_ids ?? []) tabGroupOf.set(id, g.id);
    return { id: g.id, name: g.name ?? "", pane_id: g.pane_id, tab_ids: [...(g.tab_ids ?? [])] };
  });
  for (const tab of tabs) tab.group_id = tabGroupOf.get(tab.id) ?? null;
  const workspaceGroups = (raw.workspaceGroups ?? []).map((g) => ({ id: g.id, name: g.name ?? "" }));

  const focusedWorkspace = workspaces.find((w) => w.focused)?.id ?? null;
  const focusedScreen =
    screens.find((s) => s.workspace_id === focusedWorkspace && s.focused)?.id ??
    screens.find((s) => s.workspace_id === focusedWorkspace)?.id ??
    null;
  return {
    workspaces,
    workspaceGroups,
    screens,
    panes,
    tabs,
    tabGroups,
    texts: { ...(raw.texts ?? {}) },
    focus: {
      workspace_id: focusedWorkspace,
      screen_id: focusedScreen,
      pane_id: screenOf.get(focusedScreen)?.active_pane_id ?? null,
    },
  };
}

/**
 * Reads one session's state through the cmux CLI. `cmux(args)` runs the CLI
 * against the eval session and returns parsed JSON (or throws).
 * `textFor(tab)` decides which terminals get their screen text read.
 */
export async function capture(cmux, { textFor = () => false } = {}) {
  const workspaces = await cmux(["workspace", "list"]);
  const placements = await cmux(["workspace", "placement", "list"]);
  const workspaceGroups = await cmux(["workspace", "group", "list"]);
  const screens = [];
  for (const w of workspaces) {
    for (const s of await cmux(["workspace", w.id, "screen", "list"])) {
      screens.push({ ...s, workspace_id: s.workspace_id ?? w.id });
    }
  }
  const layouts = {};
  for (const s of screens) layouts[s.id] = await cmux(["screen", s.id, "layout", "export"]);
  const panes = await cmux(["pane", "list"]);
  const tabs = await cmux(["tab", "list"]);
  const tabGroups = await cmux(["tab", "group", "list"]);
  const terminals = await cmux(["terminal", "list"]);
  const texts = {};
  for (const tab of tabs) {
    if (tab.content_kind !== "terminal" || !textFor(tab)) continue;
    let text = "";
    try {
      const history = await cmux(["terminal", tab.content_id, "history", "read"]);
      text += (history?.rows ?? []).map((r) => (typeof r === "string" ? r : (r.text ?? ""))).join("\n");
    } catch {}
    try {
      const screen = await cmux(["terminal", tab.content_id, "screen", "read"]);
      text += `\n${typeof screen === "string" ? screen : (screen?.text ?? "")}`;
    } catch {}
    texts[tab.content_id] = text;
  }
  return { workspaces, placements, workspaceGroups, screens, layouts, panes, tabs, tabGroups, terminals, texts };
}
