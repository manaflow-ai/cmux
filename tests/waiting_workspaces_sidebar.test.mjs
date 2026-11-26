import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const runtime = read("../Packages/macOS/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources/SidebarRuntime.js");
const source = read("../Examples/CustomSidebars/waiting-workspaces.js");

// Mount the actual retained scene runtime with only its native bridge replaced.
function mount() {
  const nodes = new Map();
  const commands = [];
  let root;
  const context = vm.createContext({
    __host_action: (json) => commands.push(JSON.parse(json)),
    __host_applyOps(json) {
      for (const op of JSON.parse(json)) {
        switch (op.op) {
          case "create": nodes.set(op.id, { id: op.id, children: [] }); break;
          case "update": nodes.get(op.id)[op.key] = op.value; break;
          case "children": nodes.get(op.id).children = op.children; break;
          case "remove": nodes.delete(op.id); break;
          case "root": root = op.id; break;
        }
      }
    },
  });
  vm.runInContext(runtime, context);
  vm.runInContext(source, context);
  function walk(id, parents = []) {
    const node = nodes.get(id);
    return [{ node, parents }, ...node.children.flatMap((child) => walk(child, [node, ...parents]))];
  }
  return {
    commands,
    set(key, value) { context.__setData(key, JSON.stringify(value)); },
    labels() { return walk(root).map(({ node }) => node.text).filter(Boolean); },
    prop(label, name) { return walk(root).find(({ node }) => node.text === label).node[name]; },
    click(label) {
      const { node, parents } = walk(root).find(({ node }) => node.text === label);
      const target = [node, ...parents].find((node) => node.tappable);
      context.__dispatch(target.id, "tap", "{}");
    },
  };
}

function workspace(id, group, pinned = false) {
  return { id, title: id, group, pinned, tabs: [], agents: [] };
}

function tab(name) {
  return { id: "panel-" + name, surfaceId: "surface-" + name, title: name };
}

function waiting(id, tab, sinceEpoch) {
  return { id, status: "needs_input", panelId: tab.id, surfaceId: tab.surfaceId, sinceEpoch };
}

test("jump to the oldest distinct terminal, even in a collapsed group", () => {
  const ui = mount();
  const pair = workspace("Pair", "a");
  const hidden = workspace("Hidden", "b");
  pair.tabs = [tab("Left"), tab("Right")];
  hidden.tabs = [tab("Hidden terminal")];
  pair.agents = [
    waiting("early", pair.tabs[1], 40), waiting("later", pair.tabs[1], 42),
    { id: "busy", surfaceId: pair.tabs[0].surfaceId, status: "working" },
  ];
  hidden.agents = [waiting("oldest", hidden.tabs[0], 10)];
  ui.set("groups", [
    { id: "a", name: "A", anchorId: pair.id, collapsed: false },
    { id: "b", name: "B", anchorId: hidden.id, collapsed: true },
  ]);
  ui.set("workspaces", [pair, hidden]);
  assert.equal(ui.labels()[0], "Waiting for you · 2");
  assert.equal(ui.labels().filter((text) => text === "Waiting · 1").length, 2);
  assert(!ui.labels().includes("Hidden terminal"));
  assert.deepEqual(ui.commands, []);
  ui.click("Waiting for you · 2");
  assert.deepEqual(ui.commands.pop(), {
    kind: "cmux", method: "surface.focus", params: { workspace_id: "Hidden", surface_id: "surface-Hidden terminal" },
  });
  assert.equal(ui.labels()[0], "Waiting for you · 2");
  hidden.agents[0].status = "idle";
  ui.set("workspaces", [pair, hidden]);
  ui.click("Waiting for you · 1");
  assert.deepEqual(ui.commands.pop().params, { workspace_id: "Pair", surface_id: "surface-Right" });
  ui.click("B");
  assert.deepEqual(ui.commands.pop(), { kind: "cmux", method: "workspace.group.expand", params: { group_id: "b" } });
});

test("waiting priority preserves pins, other groups and the latest manual order", () => {
  const ui = mount();
  const anchor = workspace("Anchor", "a"), pinned = workspace("Pinned", "a", true);
  const target = workspace("Target", "a"), other = workspace("Other", "b");
  target.tabs = [tab("Response")];
  target.agents = [waiting("agent", target.tabs[0], 100)];
  ui.set("groups", [
    { id: "a", name: "A", anchorId: anchor.id }, { id: "b", name: "B", anchorId: other.id },
  ]);
  const names = [anchor.id, pinned.id, target.id, other.id, "A", "B"];
  const order = () => ui.labels().filter((text) => names.includes(text));
  ui.set("workspaces", [anchor, pinned, other, target]);
  assert.deepEqual(order(), ["A", "Pinned", "Target", "Anchor", "B", "Other"]);
  ui.set("workspaces", [target, pinned, anchor, other]);
  assert.deepEqual(order(), ["A", "Pinned", "Target", "Anchor", "B", "Other"]);
  target.agents = [];
  ui.set("workspaces", [anchor, pinned, other, target]);
  assert.deepEqual(order(), ["A", "Pinned", "Anchor", "Target", "B", "Other"]);
  assert.deepEqual(ui.commands, []);
});

test("each tab retains its branch and directory and updates its last prompt", () => {
  const ui = mount();
  const w = workspace("Review");
  w.description = "Review the import";
  w.tabs = [{ ...tab("Code"), branch: "feat/import", dirty: true, directory: "/src/code" },
    { ...tab("Tests"), branch: "main", directory: "/src/tests", latestPrompt: "Verify tests" }];
  ui.set("workspaces", [w]);
  assert.deepEqual(ui.labels(), [
    "Review", "Details", "Review the import", "Code", "feat/import *", "/src/code",
    "Tests", "main", "/src/tests", "Last prompt: Verify tests",
  ]);
  assert.equal(ui.prop("Review the import", "lineLimit"), 2);
  ui.click("Details");
  assert.equal(ui.prop("Review the import", "lineLimit"), null);
  assert.equal(ui.prop("/src/tests", "lineLimit"), null);
  assert.deepEqual(ui.commands, []);
  delete w.description;
  w.latestPrompt = "Review again";
  w.tabs[0].branch = "fix/import";
  ui.set("workspaces", [w]);
  assert(ui.labels().includes("Last prompt: Review again"));
  assert(ui.labels().includes("fix/import *"));
  assert(!ui.labels().includes("feat/import *"));
  ui.click("Tests");
  assert.deepEqual(ui.commands.pop().params, { workspace_id: "Review", surface_id: "surface-Tests" });
});

test("a retired surface cannot mark a reused panel or steal the jump", () => {
  const ui = mount();
  const w = workspace("Remote");
  w.tabs = [tab("tmux")];
  w.agents = [waiting("retired", { ...w.tabs[0], surfaceId: "previous" }, 0)];
  ui.set("workspaces", [w]);
  assert(!ui.labels().some((text) => text.includes("Waiting")));
  w.agents = [{ id: "current", panelId: w.tabs[0].id, status: "needs_input" }];
  ui.set("workspaces", [w]);
  ui.click("Waiting for you · 1");
  assert.deepEqual(ui.commands.pop().params, { workspace_id: "Remote", surface_id: "surface-tmux" });
  w.agents[0].status = "ended";
  ui.set("workspaces", [w]);
  assert(!ui.labels().some((text) => text.includes("Waiting")));
});

test("empty group headers keep their model positions inside the pinned and ordinary tiers", () => {
  const ui = mount();
  const groups = [
    { id: "a", name: "Empty pinned", pinned: true },
    { id: "b", name: "Live pinned", pinned: true, anchorId: "B" },
    { id: "c", name: "Trailing pin", pinned: true },
    { id: "d", name: "Empty project" },
    { id: "e", name: "Live project", anchorId: "E" },
  ];
  ui.set("groups", groups);
  ui.set("workspaces", [workspace("E", "e"), workspace("Solo", undefined, true), workspace("B", "b")]);
  assert.deepEqual(ui.labels().filter((t) => t !== "Details"), [
    "Solo", "Empty pinned", "Live pinned", "B", "Trailing pin", "Empty project", "Live project", "E",
  ]);
  ui.click("Empty pinned");
  assert.deepEqual(ui.commands.pop(), { kind: "cmux", method: "workspace.group.collapse", params: { group_id: "a" } });
  ui.set("workspaces", []);
  assert.deepEqual(ui.labels(), groups.map((g) => g.name));
});

test("a completed or idle session on a shared terminal cannot hide live work", () => {
  const ui = mount();
  const w = workspace("Shared");
  w.tabs = [tab("Sessions")];
  for (const states of [["ended", "working", "idle"], ["idle", "working", "ended"], ["working", "ended"]]) {
    w.agents = states.map((status, i) => ({ id: String(i), status, surfaceId: w.tabs[0].surfaceId }));
    ui.set("workspaces", [w]);
    assert(ui.labels().includes("Working"));
    assert(!ui.labels().includes("Ended"));
    assert(!ui.labels().includes("Idle"));
  }
});
