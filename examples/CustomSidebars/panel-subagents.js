// panel-subagents: right-sidebar demo. Every coding-agent session cmux is
// tracking (Claude Code, Codex, ...), grouped by workspace: status dot,
// first-prompt title, live elapsed time, kind + directory metadata, and a
// working/needs-input/idle summary. Click a row to jump to the workspace and
// focus the terminal the agent runs in.
//   cp Examples/CustomSidebars/panel-subagents.js ~/.config/cmux/sidebars/
//   cmux right-sidebar set custom panel-subagents

const [query, setQuery] = signal("");
const [scopeAll, setScopeAll] = signal(true);
const [showEnded, setShowEnded] = signal(false);

// Status vocabulary (workspaces[i].agents[j].status). In-flight states get a
// strong dot; settled states are muted, matching how a roster reads at a
// glance: color answers "does anything need me?", text answers "what is it?".
const STATUS = {
  needs_input: { color: "#FF9F0A", label: "Needs input", rank: 0 },
  working: { color: "#0A84FF", label: "Working", rank: 1 },
  idle: { color: "#34C759", label: "Idle", rank: 2 },
  ended: { color: "#7f7f7f66", label: "Ended", rank: 3 },
};
const statusOf = (a) => STATUS[a.status] ?? { color: "#7f7f7f66", label: a.status, rank: 9 };

// Ended sessions stay visible briefly (a just-finished agent is still news),
// then hide behind the Ended toggle.
const ENDED_VISIBLE_SECS = 15 * 60;

const matches = (text) => {
  const q = query().trim().toLowerCase();
  if (!q) return true;
  return String(text ?? "").toLowerCase().includes(q);
};

function fmtElapsed(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m " + String(s % 60).padStart(2, "0") + "s";
  return Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m";
}

function fmtAgo(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// Right-aligned time column: live elapsed for in-flight states (ticks with
// the 1s clock), "ago" for settled ones.
function timeText(a, epoch) {
  if ((a.status === "working" || a.status === "needs_input") && a.sinceEpoch) {
    return fmtElapsed(epoch - a.sinceEpoch);
  }
  if (a.lastActivityAt) return fmtAgo(epoch - a.lastActivityAt) + " ago";
  return "";
}

const dirTail = (d) => {
  const parts = String(d ?? "").split("/").filter((p) => p.length > 0);
  return parts.length ? parts[parts.length - 1] : "";
};

// One flat entry list: workspace headers + agent rows, so a single keyed
// ForEach owns the whole roster (kind is encoded in the key, so templates
// stay stable across live updates).
const entries = computed(() => {
  const epoch = data.clock()?.epoch ?? 0;
  const all = data.workspaces() ?? [];
  const scoped = scopeAll() ? all : all.filter((w) => w.selected);
  const out = [];
  for (const w of scoped) {
    const rows = [];
    for (const a of w.agents ?? []) {
      if (a.status === "ended" && !showEnded()
          && epoch - (a.lastActivityAt ?? 0) > ENDED_VISIBLE_SECS) continue;
      if (!matches(a.title) && !matches(a.name) && !matches(a.kind)
          && !matches(w.title) && !matches(a.directory)) continue;
      rows.push({
        key: "a:" + w.id + ":" + a.id,
        kind: "agent",
        wsId: w.id,
        wsSelected: w.selected,
        agent: a,
      });
    }
    if (rows.length === 0) continue;
    rows.sort((x, y) =>
      (statusOf(x.agent).rank - statusOf(y.agent).rank)
      || ((y.agent.lastActivityAt ?? 0) - (x.agent.lastActivityAt ?? 0)));
    out.push({
      key: "h:" + w.id,
      kind: "header",
      wsId: w.id,
      wsTitle: w.title,
      wsSelected: w.selected,
      dots: rows.map((r) => statusOf(r.agent).color),
    });
    // Each agent expands into its row plus one indented row per child
    // (Claude Task spawns / Codex subagent runs), running children first.
    for (const r of rows) {
      out.push(r);
      const children = [...(r.agent.children ?? [])];
      children.sort((x, y) => (x.running === y.running ? (x.startedEpoch ?? 0) - (y.startedEpoch ?? 0) : x.running ? -1 : 1));
      for (const c of children) {
        out.push({
          key: "c:" + w.id + ":" + r.agent.id + ":" + c.id,
          kind: "child",
          wsId: w.id,
          agent: r.agent,
          child: c,
        });
      }
    }
  }
  return out;
});

const counts = computed(() => {
  const all = data.workspaces() ?? [];
  const c = { working: 0, needs_input: 0, idle: 0, ended: 0 };
  for (const w of all) {
    for (const a of w.agents ?? []) {
      if (c[a.status] !== undefined) c[a.status] += 1;
    }
  }
  return c;
});

function jump(row) {
  cmux("workspace.select", { workspace_id: row.wsId });
  if (row.agent.surfaceId) cmux("surface.focus", { surface_id: row.agent.surfaceId });
}

function toggleButton(labelFn, activeFn, onTapFn) {
  return Text(labelFn)
    .font(11).weight("semibold")
    .paddingHorizontal(8).paddingVertical(3)
    .cornerRadius(6)
    .color(() => (activeFn() ? "primary" : "tertiary"))
    .background(() => (activeFn() ? "#7f7f7f3d" : null))
    .hoverBackground("#7f7f7f3d")
    .onTap(onTapFn);
}

// Workspace header: title + one mini status dot per agent (the roster's shape
// at a glance, like a phase rail).
function headerRow(entry) {
  return HStack({ spacing: 6 }, [
    Text(() => entry().wsTitle || "untitled")
      .font(11).weight("semibold").lineLimit(1).truncation("tail")
      .color(() => (entry().wsSelected ? "primary" : "tertiary")),
    Spacer(),
    ForEach(
      { items: () => entry().dots.map((c, i) => ({ id: String(i) + c, color: c })), key: (d) => d.id },
      (d) => Circle({ size: 5 }).fill(() => d().color)
    ),
  ])
    .paddingHorizontal(10).paddingVertical(4)
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: entry().wsId }));
}

// Agent row, t3code-style: dot + identity + time column on the first line,
// status/activity on the second, kind + directory metadata on the third.
function agentRow(entry) {
  const a = () => entry().agent;
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Circle({ size: 6 }).fill(() => statusOf(a()).color),
      Text(() => a().title || a().name)
        .font(12).weight("medium").lineLimit(1).truncation("tail")
        .color(() => (a().status === "ended" ? "tertiary" : "primary")),
      Spacer(),
      Text(() => timeText(a(), data.clock()?.epoch ?? 0))
        .font(10).monospaced().color("tertiary"),
    ]),
    HStack({ spacing: 6 }, [
      Text(() => statusOf(a()).label)
        .font(10)
        .color(() => (a().status === "needs_input" ? "#FF9F0A" : "tertiary")),
      Text(() => {
        const meta = [a().name];
        const tail = dirTail(a().directory);
        if (tail) meta.push(tail);
        return meta.join(" · ");
      })
        .font(10).monospaced().color("tertiary").lineLimit(1).truncation("middle"),
      Spacer(),
    ]).paddingLeading(12),
  ])
    .paddingHorizontal(10).paddingVertical(5)
    .cornerRadius(8)
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => jump(entry()));
}

// Child (subagent) row: indented under its parent with a tree tick. Running
// children tick a live elapsed; settled ones show their total, muted.
function childRow(entry) {
  const c = () => entry().child;
  return HStack({ spacing: 6 }, [
    Text("└").font(10).monospaced().color("tertiary"),
    Circle({ size: 5 })
      .fill(() => (c().running ? "#0A84FF" : "#7f7f7f55")),
    Text(() => c().label || "subagent")
      .font(11).lineLimit(1).truncation("tail")
      .color(() => (c().running ? "secondary" : "tertiary")),
    Spacer(),
    Text(() => {
      const epoch = data.clock()?.epoch ?? 0;
      const end = c().running ? epoch : (c().endedEpoch ?? epoch);
      const s = Math.max(0, Math.floor(end - (c().startedEpoch ?? end)));
      if (s < 60) return s + "s";
      const m = Math.floor(s / 60);
      return m < 60 ? m + "m " + String(s % 60).padStart(2, "0") + "s" : Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m";
    })
      .font(10).monospaced().color("tertiary"),
  ])
    .paddingLeading(24).paddingTrailing(10).paddingVertical(3)
    .cornerRadius(7)
    .hoverBackground("#7f7f7f1c")
    .frame({ maxWidth: "infinity" })
    .onTap(() => jump(entry()));
}

sidebar(() =>
  VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Text("Agents").font(14).weight("semibold"),
      Spacer(),
      Text(() => {
        const c = counts();
        const live = c.working + c.needs_input;
        const bits = [];
        if (live > 0) bits.push("● " + live + " working");
        if (c.idle > 0) bits.push(c.idle + " idle");
        if (c.ended > 0) bits.push(c.ended + " ended");
        return bits.join(" · ");
      }).font(10).monospaced().color("tertiary"),
    ]).paddingHorizontal(10),

    HStack({ spacing: 4 }, [
      toggleButton("This workspace", () => !scopeAll(), () => setScopeAll(false)),
      toggleButton("All", () => scopeAll(), () => setScopeAll(true)),
      Spacer(),
      toggleButton("Ended", () => showEnded(), () => setShowEnded(!showEnded())),
    ]).paddingHorizontal(10),

    TextField("", {
      placeholder: "Search agents",
      autofocus: false,
      onEdit: (t) => setQuery(t ?? ""),
      onSubmit: (t) => setQuery(t ?? ""),
    }).paddingHorizontal(10),

    ForEach(
      { items: entries, key: (e) => e.key },
      (e) => {
        const entry = e(); // kind is stable per key
        if (entry.kind === "header") return headerRow(e);
        if (entry.kind === "child") return childRow(e);
        return agentRow(e);
      }
    ),

    Text(() => (entries().length === 0
      ? (query().trim()
        ? "No matches."
        : "No agents yet. Sessions started in cmux terminals show up here with live status.")
      : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
