// Unit tests for the agent-evals graders (plans/cmux-next/agent-evals-DESIGN.md).
// Snapshots are built in the shape the cmux CLI prints (--json), so the
// normalizer is covered too. No daemon is needed.
import { describe, expect, test } from "bun:test";
import { columnsOf, normalize } from "./snapshot.mjs";
import { CATEGORIES, CHECKS, gradeTask } from "./grade.mjs";
import { TASKS } from "./tasks.mjs";

// world({ ws, screens, tabs, tabGroups, groups, texts }) → a raw CLI snapshot.
// screens: { id, ws, focused, active, columns: [{ panes: [...], dock? }] }
// tabs: { id, pane, name?, title?, kind? }
function world({ ws, screens, tabs, tabGroups = [], groups = [], texts = {} }) {
  const layouts = {};
  for (const s of screens) {
    const columns = s.columns.map((c, i) => ({
      column_id: `split_${s.id}_${i}`,
      ...(c.dock ? { dock: { edge: "right", mode: "docked" } } : {}),
      root:
        c.panes.length === 1
          ? leaf(c.panes[0], tabs)
          : c.panes
              .slice(1)
              .reduce((acc, p) => ({ kind: "split", direction: "vertical", ratio: 0.5, first: acc, second: leaf(p, tabs) }), leaf(c.panes[0], tabs)),
      width: i === 0 ? 1 : 0.5,
    }));
    layouts[s.id] = {
      active_pane_id: s.active,
      screen_id: s.id,
      root: columns.length === 1 && !s.viewport ? columns[0].root : { kind: "viewport", base_width: 1, columns },
    };
  }
  return {
    workspaces: ws.map((w, index) => ({ id: w.id, name: w.name, focused: !!w.focused, index })),
    placements: ws.map((w, index) => ({ group_id: w.group ?? null, index, workspace: { workspace_id: w.id } })),
    workspaceGroups: groups,
    screens: screens.map((s, index) => ({ id: s.id, workspace_id: s.ws, focused: !!s.focused, index })),
    layouts,
    panes: screens.flatMap((s) =>
      s.columns.flatMap((c) => c.panes.map((p) => ({ id: p, screen_id: s.id, focused: p === s.active }))),
    ),
    tabs: tabs.map((t, index) => ({
      id: t.id,
      pane_id: t.pane,
      name: t.name ?? null,
      content_kind: t.kind ?? "terminal",
      content_id: `term_${t.id}`,
      index,
    })),
    tabGroups,
    terminals: tabs
      .filter((t) => (t.kind ?? "terminal") === "terminal")
      .map((t) => ({ id: `term_${t.id}`, tab_id: t.id, title: t.title ?? "" })),
    texts: Object.fromEntries(Object.entries(texts).map(([tab, text]) => [`term_${tab}`, text])),
  };
}
function leaf(pane, tabs) {
  const ids = tabs.filter((t) => t.pane === pane).map((t) => t.id);
  return { kind: "leaf", pane_id: pane, tab_ids: ids, active_tab_id: ids[0] ?? null };
}

const ORIGIN = { workspace_id: "ws_o", screen_id: "s_o", pane_id: "p_o", tab_id: "t_o" };
const base = (extra = {}) => ({
  ws: [{ id: "ws_o", name: "home", focused: true }, ...(extra.ws ?? [])],
  screens: [
    { id: "s_o", ws: "ws_o", focused: true, active: "p_o", columns: [{ panes: ["p_o"] }, ...(extra.columns ?? [])] },
    ...(extra.screens ?? []),
  ],
  tabs: [{ id: "t_o", pane: "p_o", name: "me" }, ...(extra.tabs ?? [])],
  tabGroups: extra.tabGroups ?? [],
  groups: extra.groups ?? [],
  texts: extra.texts ?? {},
});
const ctx = (before, after, more = {}) => ({
  before: normalize(world(before)),
  after: normalize(world(after)),
  origin: ORIGIN,
  aliases: more.aliases ?? {},
  answer: more.answer ?? "",
  calls: more.calls ?? [],
  markers: more.markers ?? {},
});
const run = (name, c, params = {}) => CHECKS[name](c, params);

describe("normalize", () => {
  test("assigns column index and dock from the viewport layout", () => {
    const m = normalize(
      world(base({ columns: [{ panes: ["p_r", "p_r2"] }, { panes: ["p_d"], dock: true }], tabs: [{ id: "t_r", pane: "p_r" }] })),
    );
    const pane = (id) => m.panes.find((p) => p.id === id);
    expect(pane("p_o").column_index).toBe(0);
    expect(pane("p_r").column_index).toBe(1);
    expect(pane("p_r2").column_index).toBe(1);
    expect(pane("p_d").docked).toBe(true);
    expect(pane("p_r").docked).toBe(false);
    expect(m.screens[0].column_count).toBe(3);
  });
  test("a horizontal split is two columns; a vertical split stacks", () => {
    const layout = {
      root: {
        kind: "split",
        direction: "horizontal",
        first: { kind: "leaf", pane_id: "a" },
        second: { kind: "split", direction: "vertical", first: { kind: "leaf", pane_id: "b" }, second: { kind: "leaf", pane_id: "c" } },
      },
    };
    const cols = columnsOf(layout);
    expect(cols.map((c) => c.pane_ids)).toEqual([["a"], ["b", "c"]]);
  });
  test("a single leaf screen has one column", () => {
    const m = normalize(world(base()));
    expect(m.panes[0].column_index).toBe(0);
    expect(m.screens[0].column_count).toBe(1);
  });
  test("workspace group comes from placements; tab name falls back to the terminal title", () => {
    const m = normalize(world(base({ ws: [{ id: "ws_a", name: "api", group: "grp_1" }], tabs: [{ id: "t_x", pane: "p_o", title: "vim" }] })));
    expect(m.workspaces.find((w) => w.id === "ws_a").group_id).toBe("grp_1");
    expect(m.tabs.find((t) => t.id === "t_x").label).toBe("vim");
    expect(m.focus).toEqual({ workspace_id: "ws_o", screen_id: "s_o", pane_id: "p_o" });
  });
});

describe("placement checks", () => {
  const right = (tabs = [{ id: "t_n", pane: "p_r" }], columns = [{ panes: ["p_r"] }]) => base({ columns, tabs });
  test("a new tab right of the origin passes; one in the origin pane fails", () => {
    expect(run("new_tabs_right_of_origin", ctx(base(), right())).ok).toBe(true);
    expect(run("new_tabs_right_of_origin", ctx(base(), base({ tabs: [{ id: "t_n", pane: "p_o" }] }))).ok).toBe(false);
  });
  test("no new tab fails the right-of-origin check", () => {
    expect(run("new_tabs_right_of_origin", ctx(base(), base())).ok).toBe(false);
  });
  test("a docked column is not the right column", () => {
    const docked = right([{ id: "t_n", pane: "p_r" }], [{ panes: ["p_r"], dock: true }]);
    expect(run("not_docked", ctx(base(), docked)).ok).toBe(false);
    expect(run("not_docked", ctx(base(), right())).ok).toBe(true);
  });
  test("columns_added_at_most counts columns and down splits", () => {
    expect(run("columns_added_at_most", ctx(base(), right()), { n: 1 }).ok).toBe(true);
    const two = right([{ id: "t_n", pane: "p_r" }], [{ panes: ["p_r"] }, { panes: ["p_r3"] }]);
    expect(run("columns_added_at_most", ctx(base(), two), { n: 1 }).ok).toBe(false);
    const down = right([{ id: "t_n", pane: "p_r" }], [{ panes: ["p_r", "p_r2"] }]);
    expect(run("columns_added_at_most", ctx(base(), down), { n: 1 }).ok).toBe(false);
    expect(run("columns_added_at_most", ctx(right(), right([{ id: "t_n", pane: "p_r" }, { id: "t_m", pane: "p_r" }])), { n: 0 }).ok).toBe(true);
  });
  test("new_tabs_in_pane uses the setup alias", () => {
    const before = right([{ id: "t_logs", pane: "p_r" }]);
    const after = right([{ id: "t_logs", pane: "p_r" }, { id: "t_n", pane: "p_r" }]);
    const c = ctx(before, after, { aliases: { right: "p_r" } });
    expect(run("new_tabs_in_pane", c, { pane: "right" }).ok).toBe(true);
    const elsewhere = right([{ id: "t_logs", pane: "p_r" }, { id: "t_n", pane: "p_o" }]);
    expect(run("new_tabs_in_pane", ctx(before, elsewhere, { aliases: { right: "p_r" } }), { pane: "right" }).ok).toBe(false);
  });
  test("new_tabs counts tabs by kind", () => {
    const c = ctx(base(), right([{ id: "a", pane: "p_r" }, { id: "b", pane: "p_r" }]));
    expect(run("new_tabs", c, { count: 2 }).ok).toBe(true);
    expect(run("new_tabs", c, { count: 1 }).ok).toBe(false);
    expect(run("new_tabs", c, { count: 2, kind: "browser" }).ok).toBe(false);
  });
});

describe("focus and leftovers", () => {
  test("focus_kept fails when the focused pane, screen or workspace moves", () => {
    const moved = base({ columns: [{ panes: ["p_r"] }], tabs: [{ id: "t_n", pane: "p_r" }] });
    moved.screens[0].active = "p_r";
    expect(run("focus_kept", ctx(base(), moved)).ok).toBe(false);
    const ws = base({ ws: [{ id: "ws_n", name: "x" }] });
    ws.ws[0].focused = false;
    ws.ws[1].focused = true;
    expect(run("focus_kept", ctx(base(), ws)).ok).toBe(false);
    expect(run("focus_kept", ctx(base(), base())).ok).toBe(true);
  });
  test("no_new_workspaces and new_workspaces", () => {
    const one = base({ ws: [{ id: "ws_n", name: "eval-proj" }] });
    expect(run("no_new_workspaces", ctx(base(), one)).ok).toBe(false);
    expect(run("no_new_workspaces", ctx(base(), base())).ok).toBe(true);
    expect(run("new_workspaces", ctx(base(), one), { count: 1, name: "eval-proj" }).ok).toBe(true);
    expect(run("new_workspaces", ctx(base(), one), { count: 1, name: "other" }).ok).toBe(false);
  });
  test("user_tabs_kept fails when a pre-existing tab is gone", () => {
    const before = base({ tabs: [{ id: "t_a", pane: "p_o" }] });
    expect(run("user_tabs_kept", ctx(before, base())).ok).toBe(false);
    expect(run("user_tabs_kept", ctx(before, before)).ok).toBe(true);
  });
  test("layout_unchanged sees new tabs, groups and renames", () => {
    expect(run("layout_unchanged", ctx(base(), base())).ok).toBe(true);
    expect(run("layout_unchanged", ctx(base(), base({ tabs: [{ id: "t_n", pane: "p_o" }] }))).ok).toBe(false);
    expect(run("layout_unchanged", ctx(base(), base({ groups: [{ id: "g", name: "x" }] }))).ok).toBe(false);
    const renamed = base();
    renamed.ws[0].name = "renamed";
    expect(run("layout_unchanged", ctx(base(), renamed)).ok).toBe(false);
  });
  test("workspaces_kept fails on close or rename", () => {
    const before = base({ ws: [{ id: "ws_a", name: "api" }] });
    expect(run("workspaces_kept", ctx(before, base())).ok).toBe(false);
    const renamed = base({ ws: [{ id: "ws_a", name: "API!" }] });
    expect(run("workspaces_kept", ctx(before, renamed)).ok).toBe(false);
    expect(run("workspaces_kept", ctx(before, before)).ok).toBe(true);
  });
});

describe("work done", () => {
  test("terminal_text_contains looks in new tabs or an alias", () => {
    const after = base({ columns: [{ panes: ["p_r"] }], tabs: [{ id: "t_n", pane: "p_r" }], texts: { t_n: "$ echo X\nEVAL_OK\n" } });
    expect(run("terminal_text_contains", ctx(base(), after), { text: "EVAL_OK" }).ok).toBe(true);
    // The typed command alone is not the output.
    const echoOnly = base({ columns: [{ panes: ["p_r"] }], tabs: [{ id: "t_n", pane: "p_r" }], texts: { t_n: "$ echo EVAL_OK" } });
    expect(run("terminal_text_contains", ctx(base(), echoOnly), { text: "EVAL_OK", output_line: true }).ok).toBe(false);
  });
  test("tab_names_cover needs each word on a distinct new tab", () => {
    const tabs = [
      { id: "a", pane: "p_r", name: "build" },
      { id: "b", pane: "p_r", name: "Test runner" },
      { id: "c", pane: "p_r", title: "lint" },
    ];
    const c = ctx(base(), base({ columns: [{ panes: ["p_r"] }], tabs }));
    expect(run("tab_names_cover", c, { words: ["build", "test", "lint"] }).ok).toBe(true);
    expect(run("tab_names_cover", c, { words: ["build", "test", "deploy"] }).ok).toBe(false);
  });
  test("markers_present needs each role to have run in a distinct new terminal", () => {
    const tabs = [{ id: "a", pane: "p_r" }, { id: "b", pane: "p_r" }];
    const c = (markers) => ctx(base(), base({ columns: [{ panes: ["p_r"] }], tabs }), { markers });
    expect(run("markers_present", c({ build: "term_a", test: "term_b" }), { roles: ["build", "test"] }).ok).toBe(true);
    expect(run("markers_present", c({ build: "term_a", test: "term_a" }), { roles: ["build", "test"] }).ok).toBe(false);
    expect(run("markers_present", c({ build: "term_a" }), { roles: ["build", "test"] }).ok).toBe(false);
    expect(run("markers_present", c({ build: "term_o", test: "term_b" }), { roles: ["build", "test"] }).ok).toBe(false);
  });
  test("answer_contains is case-insensitive", () => {
    expect(run("answer_contains", ctx(base(), base(), { answer: "The code is e4271." }), { text: "E4271" }).ok).toBe(true);
    expect(run("answer_contains", ctx(base(), base(), { answer: "no idea" }), { text: "E4271" }).ok).toBe(false);
  });
  test("workspace_side_by_side finds the named workspace's two columns and its right text", () => {
    const after = base({
      ws: [{ id: "ws_n", name: "eval-proj" }],
      screens: [{ id: "s_n", ws: "ws_n", active: "p_a", columns: [{ panes: ["p_a"] }, { panes: ["p_b"] }] }],
      tabs: [{ id: "ta", pane: "p_a" }, { id: "tb", pane: "p_b" }],
      texts: { tb: "EVAL_WS_OK\n" },
    });
    expect(run("workspace_side_by_side", ctx(base(), after), { name: "eval-proj", text: "EVAL_WS_OK" }).ok).toBe(true);
    after.texts = { ta: "EVAL_WS_OK\n" };
    expect(run("workspace_side_by_side", ctx(base(), after), { name: "eval-proj", text: "EVAL_WS_OK" }).ok).toBe(false);
  });
});

describe("grouping", () => {
  const tabs = [
    { id: "s1", pane: "p_r", name: "server" },
    { id: "s2", pane: "p_r", name: "server logs" },
    { id: "u1", pane: "p_r", name: "unit tests" },
    { id: "u2", pane: "p_r", name: "test watcher" },
  ];
  const withGroups = (tabGroups) => base({ columns: [{ panes: ["p_r"] }], tabs, tabGroups });
  const g = (id, name, ids) => ({ id, name, pane_id: "p_r", tab_ids: ids });
  test("tabs_grouped_together and apart", () => {
    const good = ctx(withGroups([]), withGroups([g("g1", "Server", ["s1", "s2"]), g("g2", "Tests", ["u1", "u2"])]));
    expect(run("tabs_grouped_together", good, { names: ["server", "server logs"] }).ok).toBe(true);
    expect(run("tabs_grouped_apart", good, { a: "server", b: "unit tests" }).ok).toBe(true);
    const lumped = ctx(withGroups([]), withGroups([g("g1", "All", ["s1", "s2", "u1", "u2"])]));
    expect(run("tabs_grouped_apart", lumped, { a: "server", b: "unit tests" }).ok).toBe(false);
    const none = ctx(withGroups([]), withGroups([]));
    expect(run("tabs_grouped_together", none, { names: ["server", "server logs"] }).ok).toBe(false);
    expect(run("tabs_grouped_apart", none, { a: "server", b: "unit tests" }).ok).toBe(false);
  });
  test("tab_group_exact matches the new tabs", () => {
    const before = base();
    const after = (ids) => base({ columns: [{ panes: ["p_r"] }], tabs: tabs.slice(0, 3), tabGroups: [g("g", "Checks", ids)] });
    expect(run("tab_group_exact", ctx(before, after(["s1", "s2", "u1"]))).ok).toBe(true);
    expect(run("tab_group_exact", ctx(before, after(["s1", "s2"]))).ok).toBe(false);
  });
  test("group_name_matches checks the shared group's name", () => {
    const c = ctx(withGroups([]), withGroups([g("g1", "Server stuff", ["s1", "s2"])]));
    expect(run("group_name_matches", c, { kind: "tab", members: ["server"], words: ["server", "backend"] }).ok).toBe(true);
    expect(run("group_name_matches", c, { kind: "tab", members: ["server"], words: ["frontend"] }).ok).toBe(false);
  });
  test("workspaces grouped together, apart, and the origin's group name", () => {
    const ws = (a, b, c2, d) => [
      { id: "w1", name: "api: server", group: a },
      { id: "w2", name: "api: migrations", group: b },
      { id: "w3", name: "web: landing page", group: c2 },
      { id: "w4", name: "web: dashboard", group: d },
    ];
    const groups = [{ id: "gA", name: "API" }, { id: "gW", name: "Web" }];
    const good = ctx(base({ ws: ws() }), base({ ws: ws("gA", "gA", "gW", "gW"), groups }));
    expect(run("workspaces_grouped_together", good, { names: ["api: server", "api: migrations"] }).ok).toBe(true);
    expect(run("workspaces_grouped_apart", good, { a: "api: server", b: "web: dashboard" }).ok).toBe(true);
    expect(run("group_name_matches", good, { kind: "workspace", members: ["api: server"], words: ["api"] }).ok).toBe(true);
    const ungrouped = ctx(base({ ws: ws() }), base({ ws: ws() }));
    expect(run("workspaces_grouped_together", ungrouped, { names: ["api: server", "api: migrations"] }).ok).toBe(false);
    const origin = base({ groups: [{ id: "gS", name: "Shop" }] });
    origin.ws[0].group = "gS";
    expect(run("workspace_in_group", ctx(base(), origin), { workspace: "origin", words: ["shop"] }).ok).toBe(true);
    expect(run("workspace_in_group", ctx(base(), base()), { workspace: "origin", words: ["shop"] }).ok).toBe(false);
  });
});

describe("stayed_in_session", () => {
  test("a call that names another socket or session fails", () => {
    const ok = ctx(base(), base(), { calls: [{ argv: ["--json", "tab", "list"] }] });
    expect(run("stayed_in_session", ok).ok).toBe(true);
    for (const flag of ["--socket", "--session", "--app-socket", "--all-sessions"]) {
      const bad = ctx(base(), base(), { calls: [{ argv: [flag, "x", "tab", "list"] }] });
      expect(run("stayed_in_session", bad).ok).toBe(false);
    }
  });
});

describe("gradeTask", () => {
  const task = {
    id: "t",
    checks: [
      { check: "new_tabs", params: { count: 1 }, required: true },
      { check: "focus_kept", required: true },
      { check: "group_name_matches", params: { kind: "tab", members: ["x"], words: ["y"] }, required: false },
    ],
  };
  test("passes when every required check passes; bonus lowers only the score", () => {
    const r = gradeTask(task, ctx(base(), base({ columns: [{ panes: ["p_r"] }], tabs: [{ id: "x", pane: "p_r" }] })));
    expect(r.pass).toBe(true);
    expect(r.category).toBeUndefined();
    expect(r.score).toBeCloseTo(2 / 3);
  });
  test("the first failed required check names the category", () => {
    const r = gradeTask(task, ctx(base(), base()));
    expect(r.pass).toBe(false);
    expect(r.category).toBe("not_done");
    expect(CATEGORIES).toContain(r.category);
  });
  test("a check that throws fails as harness_error", () => {
    const r = gradeTask({ id: "t", checks: [{ check: "no_such_check", required: true }] }, ctx(base(), base()));
    expect(r.pass).toBe(false);
    expect(r.category).toBe("harness_error");
  });
});

describe("task catalog", () => {
  test("every task names known checks, a tier and a prompt", () => {
    const ids = new Set();
    for (const task of TASKS) {
      expect(ids.has(task.id)).toBe(false);
      ids.add(task.id);
      expect(["headless", "app"]).toContain(task.tier);
      expect(task.prompt.length).toBeGreaterThan(20);
      expect(task.checks.some((c) => c.required)).toBe(true);
      for (const c of task.checks) expect(Object.keys(CHECKS)).toContain(c.check);
    }
    expect(TASKS.filter((t) => t.tier === "headless").length).toBeGreaterThanOrEqual(8);
    expect(TASKS.filter((t) => t.tier === "app").length).toBeGreaterThanOrEqual(5);
  });
});
