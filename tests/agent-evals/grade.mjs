// Deterministic graders for agent evals (plans/cmux-next/agent-evals-DESIGN.md).
// Every check is a pure function of the grading context:
//   { before, after, origin, aliases, answer, calls, markers }
// where before/after are snapshot.mjs models, origin is the agent's own
// { workspace_id, screen_id, pane_id }, aliases maps setup names to ids,
// answer is the agent's final message, calls is the cmux call log
// ([{ argv }]) and markers maps a stub agent's role to the terminal it ran in.

import { serverReceived } from "./fixtures.mjs";

export const CATEGORIES = Object.freeze([
  "wrong_place", "extra_split", "docked", "focus_stolen", "stray_workspace", "closed_user_tab",
  "changed_layout", "not_done", "no_grouping", "wrong_grouping", "wrong_answer", "left_session",
  "timeout", "agent_error", "no_login", "harness_error",
]);

const lower = (s) => String(s ?? "").trim().toLowerCase();
const result = (ok, detail) => ({ ok: !!ok, detail });

function newTabs(ctx) {
  const before = new Set(ctx.before.tabs.map((t) => t.id));
  return ctx.after.tabs.filter((t) => !before.has(t.id));
}
const paneById = (model, id) => model.panes.find((p) => p.id === id);
const resolvePane = (ctx, name) => ctx.aliases?.[name] ?? name;
const tabByLabel = (model, label) => model.tabs.find((t) => lower(t.label) === lower(label));
const wsByName = (model, name) => model.workspaces.find((w) => lower(w.name) === lower(name));
const hasAny = (text, words) => words.some((w) => lower(text).includes(lower(w)));

function originColumn(ctx) {
  return paneById(ctx.after, ctx.origin.pane_id) ?? paneById(ctx.before, ctx.origin.pane_id);
}

function textHas(text, needle, outputLine) {
  if (!text) return false;
  if (!outputLine) return text.includes(needle);
  // The output line, not the typed command that contains the same word.
  return text.split(/\r?\n/).some((line) => line.includes(needle) && !/\becho\b|printf/.test(line));
}

function screenSignature(model) {
  return JSON.stringify({
    w: model.workspaces.map((w) => [w.id, w.name, w.group_id]),
    g: model.workspaceGroups.map((g) => [g.id, g.name]),
    p: model.panes.map((p) => [p.id, p.column_index, p.docked]).sort(),
    t: model.tabs.map((t) => [t.id, t.pane_id, t.name]).sort(),
    tg: model.tabGroups.map((g) => [g.id, g.name, [...g.tab_ids].sort()]).sort(),
    s: model.screens.map((s) => [s.id, s.column_count]),
  });
}

function sharedGroup(model, kind, names) {
  const items = names.map((n) => (kind === "tab" ? tabByLabel(model, n) : wsByName(model, n)));
  if (items.some((i) => !i)) return { ok: false, detail: `missing ${names.filter((_, i) => !items[i]).join(", ")}` };
  const groups = new Set(items.map((i) => i.group_id));
  const [group] = groups;
  if (groups.size !== 1 || !group) return { ok: false, detail: `groups: ${items.map((i) => i.group_id ?? "none").join(", ")}` };
  return { ok: true, group };
}

export const CHECKS = Object.freeze({
  focus_kept(ctx) {
    const a = ctx.before.focus;
    const b = ctx.after.focus;
    const same = a.workspace_id === b.workspace_id && a.screen_id === b.screen_id && a.pane_id === b.pane_id;
    return result(same, same ? "" : `focus ${JSON.stringify(a)} -> ${JSON.stringify(b)}`);
  },
  no_new_workspaces(ctx) {
    const before = new Set(ctx.before.workspaces.map((w) => w.id));
    const extra = ctx.after.workspaces.filter((w) => !before.has(w.id));
    return result(extra.length === 0, extra.map((w) => w.name).join(", "));
  },
  new_workspaces(ctx, { count, name }) {
    const before = new Set(ctx.before.workspaces.map((w) => w.id));
    const extra = ctx.after.workspaces.filter((w) => !before.has(w.id));
    const named = name ? extra.every((w) => lower(w.name) === lower(name)) : true;
    const r = result(extra.length === count && named, `new: ${extra.map((w) => w.name).join(", ") || "none"}`);
    // Too few is unfinished work; too many or misnamed is a stray workspace.
    return extra.length < count ? { ...r, category: "not_done" } : r;
  },
  workspaces_kept(ctx) {
    const after = new Map(ctx.after.workspaces.map((w) => [w.id, w.name]));
    const lost = ctx.before.workspaces.filter((w) => after.get(w.id) !== w.name);
    return result(lost.length === 0, lost.map((w) => w.name).join(", "));
  },
  user_tabs_kept(ctx) {
    const after = new Set(ctx.after.tabs.map((t) => t.id));
    const lost = ctx.before.tabs.filter((t) => !after.has(t.id));
    return result(lost.length === 0, lost.map((t) => t.label || t.id).join(", "));
  },
  layout_unchanged(ctx) {
    const same = screenSignature(ctx.before) === screenSignature(ctx.after);
    return result(same, same ? "" : "state changed");
  },
  new_tabs(ctx, { count, min, kind } = {}) {
    const tabs = newTabs(ctx).filter((t) => !kind || t.kind === kind);
    const ok = count !== undefined ? tabs.length === count : tabs.length >= (min ?? 1);
    return result(ok, `${tabs.length} new${kind ? ` ${kind}` : ""} tabs`);
  },
  new_tabs_right_of_origin(ctx) {
    const origin = originColumn(ctx);
    const tabs = newTabs(ctx);
    if (!origin || tabs.length === 0) return result(false, "no new tabs");
    const wrong = tabs.filter((t) => {
      const pane = paneById(ctx.after, t.pane_id);
      return !pane || pane.screen_id !== origin.screen_id || pane.column_index <= origin.column_index;
    });
    return result(wrong.length === 0, wrong.map((t) => `${t.id} in ${t.pane_id}`).join(", "));
  },
  new_tabs_in_pane(ctx, { pane }) {
    const id = resolvePane(ctx, pane);
    const tabs = newTabs(ctx);
    const wrong = tabs.filter((t) => t.pane_id !== id);
    return result(tabs.length > 0 && wrong.length === 0, `${tabs.length} new, ${wrong.length} outside ${pane}`);
  },
  not_docked(ctx) {
    const docked = newTabs(ctx).filter((t) => paneById(ctx.after, t.pane_id)?.docked);
    return result(docked.length === 0, docked.map((t) => t.id).join(", "));
  },
  columns_added_at_most(ctx, { n }) {
    const screen = ctx.origin.screen_id;
    const cols = (m) => m.screens.find((s) => s.id === screen)?.column_count ?? 0;
    const panes = (m) => m.panes.filter((p) => p.screen_id === screen).length;
    const dc = cols(ctx.after) - cols(ctx.before);
    const dp = panes(ctx.after) - panes(ctx.before);
    return result(dc <= n && dp <= n, `+${dc} columns, +${dp} panes`);
  },
  terminal_text_contains(ctx, { text, pane, output_line = false }) {
    let tabs = newTabs(ctx).filter((t) => t.kind === "terminal");
    if (pane) tabs = tabs.filter((t) => t.pane_id === resolvePane(ctx, pane));
    const hit = tabs.some((t) => textHas(ctx.after.texts[t.content_id], text, output_line));
    return result(hit, hit ? "" : `"${text}" not in ${tabs.length} new terminals`);
  },
  tab_names_cover(ctx, { words }) {
    const labels = newTabs(ctx).map((t) => lower(t.label));
    const used = new Set();
    const missing = words.filter((w) => {
      const i = labels.findIndex((l, idx) => !used.has(idx) && l.includes(lower(w)));
      if (i < 0) return true;
      used.add(i);
      return false;
    });
    return result(missing.length === 0, missing.length ? `no tab named ${missing.join(", ")}` : "");
  },
  markers_present(ctx, { roles }) {
    const fresh = new Set(newTabs(ctx).map((t) => t.content_id));
    const terms = roles.map((r) => ctx.markers?.[r]);
    const ok = terms.every((t) => t && fresh.has(t)) && new Set(terms).size === roles.length;
    return result(ok, roles.map((r, i) => `${r}:${terms[i] ?? "none"}`).join(" "));
  },
  tab_group_exact(ctx) {
    const ids = new Set(newTabs(ctx).map((t) => t.id));
    const hit = ctx.after.tabGroups.find((g) => g.tab_ids.length === ids.size && g.tab_ids.every((id) => ids.has(id)));
    return result(ids.size > 0 && !!hit, hit ? hit.name : `${ctx.after.tabGroups.length} groups, none exact`);
  },
  tabs_grouped_together(ctx, { names }) {
    const r = sharedGroup(ctx.after, "tab", names);
    return result(r.ok, r.detail ?? "");
  },
  tabs_grouped_apart(ctx, { a, b }) {
    const ta = tabByLabel(ctx.after, a);
    const tb = tabByLabel(ctx.after, b);
    const ok = ta?.group_id && tb?.group_id && ta.group_id !== tb.group_id;
    return result(ok, `${a}:${ta?.group_id ?? "none"} ${b}:${tb?.group_id ?? "none"}`);
  },
  workspaces_grouped_together(ctx, { names }) {
    const r = sharedGroup(ctx.after, "workspace", names);
    return result(r.ok, r.detail ?? "");
  },
  workspaces_grouped_apart(ctx, { a, b }) {
    const wa = wsByName(ctx.after, a);
    const wb = wsByName(ctx.after, b);
    const ok = wa?.group_id && wb?.group_id && wa.group_id !== wb.group_id;
    return result(ok, `${a}:${wa?.group_id ?? "none"} ${b}:${wb?.group_id ?? "none"}`);
  },
  group_name_matches(ctx, { kind, members, words }) {
    const r = sharedGroup(ctx.after, kind, members);
    if (!r.ok) return result(false, r.detail);
    const groups = kind === "tab" ? ctx.after.tabGroups : ctx.after.workspaceGroups;
    const name = groups.find((g) => g.id === r.group)?.name ?? "";
    return result(hasAny(name, words), `group name "${name}"`);
  },
  workspace_in_group(ctx, { workspace, words }) {
    const id = workspace === "origin" ? ctx.origin.workspace_id : wsByName(ctx.after, workspace)?.id;
    const ws = ctx.after.workspaces.find((w) => w.id === id);
    const group = ctx.after.workspaceGroups.find((g) => g.id === ws?.group_id);
    return result(!!group && hasAny(group.name, words), group ? `group "${group.name}"` : "not grouped");
  },
  workspace_side_by_side(ctx, { name, text }) {
    const ws = wsByName(ctx.after, name);
    if (!ws) return result(false, `no workspace ${name}`);
    for (const screen of ctx.after.screens.filter((s) => s.workspace_id === ws.id)) {
      const cols = screen.columns.filter((c) => !c.docked);
      if (cols.length < 2) continue;
      const rightPanes = new Set(cols.slice(1).flatMap((c) => c.pane_ids));
      const hit = ctx.after.tabs.some(
        (t) => rightPanes.has(t.pane_id) && t.kind === "terminal" && textHas(ctx.after.texts[t.content_id], text, true),
      );
      if (hit) return result(true, "");
    }
    return result(false, "no side-by-side screen with the text on the right");
  },
  server_received(ctx, { path, body }) {
    const ok = serverReceived(ctx.posts ?? [], { path, body });
    return result(ok, `${(ctx.posts ?? []).filter((p) => p.path === path).length} posts to ${path}`);
  },
  answer_contains(ctx, { text }) {
    return result(lower(ctx.answer).includes(lower(text)), ctx.answer ? "" : "no answer");
  },
  stayed_in_session(ctx) {
    // The eval session may be named outright (`--session NAME`, `--socket .../NAME.sock`,
    // `NAME:ws_…`); any other target leaves it.
    const name = ctx.session?.name;
    const sockets = ctx.session?.sockets ?? [];
    const own = (value) =>
      (!!name && (value === name || String(value).endsWith(`/${name}.sock`))) || sockets.includes(value);
    const leaves = (argv) =>
      argv.some((a, i) => {
        const [flag, inline] = a.split("=");
        if (flag === "--all-sessions") return true;
        if (flag === "--socket" || flag === "--session" || flag === "--app-socket") return !own(inline ?? argv[i + 1]);
        const routed = /^([\w.-]+):(ws|screen|pane|tab|term)_/.exec(a);
        return !!routed && !own(routed[1]);
      });
    const bad = (ctx.calls ?? []).filter((c) => leaves(c.argv ?? []));
    return result(bad.length === 0, bad.map((c) => c.argv.join(" ")).slice(0, 3).join(" | "));
  },
});

export const CHECK_CATEGORY = Object.freeze({
  focus_kept: "focus_stolen",
  no_new_workspaces: "stray_workspace",
  new_workspaces: "stray_workspace",
  workspaces_kept: "closed_user_tab",
  user_tabs_kept: "closed_user_tab",
  layout_unchanged: "changed_layout",
  new_tabs: "not_done",
  new_tabs_right_of_origin: "wrong_place",
  new_tabs_in_pane: "wrong_place",
  not_docked: "docked",
  columns_added_at_most: "extra_split",
  terminal_text_contains: "not_done",
  tab_names_cover: "not_done",
  markers_present: "not_done",
  tab_group_exact: "no_grouping",
  tabs_grouped_together: "no_grouping",
  tabs_grouped_apart: "wrong_grouping",
  workspaces_grouped_together: "no_grouping",
  workspaces_grouped_apart: "wrong_grouping",
  group_name_matches: "wrong_grouping",
  workspace_in_group: "no_grouping",
  workspace_side_by_side: "not_done",
  answer_contains: "wrong_answer",
  server_received: "not_done",
  stayed_in_session: "left_session",
});

/** Grades one task run. Returns { checks, pass, score, category? }. */
export function gradeTask(task, ctx) {
  const checks = task.checks.map((spec) => {
    const weight = spec.weight ?? 1;
    const required = !!spec.required;
    let outcome;
    try {
      const fn = CHECKS[spec.check];
      if (!fn) throw new Error(`unknown check ${spec.check}`);
      outcome = fn(ctx, spec.params ?? {});
    } catch (error) {
      return { name: spec.check, ok: false, required, weight, category: "harness_error", detail: String(error.message ?? error) };
    }
    return { name: spec.check, ok: outcome.ok, required, weight, category: outcome.category ?? CHECK_CATEGORY[spec.check], detail: outcome.detail ?? "" };
  });
  const total = checks.reduce((s, c) => s + c.weight, 0);
  const got = checks.reduce((s, c) => s + (c.ok ? c.weight : 0), 0);
  const failed = checks.find((c) => c.required && !c.ok);
  return {
    checks,
    pass: !failed,
    score: total ? got / total : 0,
    ...(failed ? { category: failed.category } : {}),
  };
}
