import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";

// Executable daemon fixture: rejects unsupported grammar and persists topology.
// Terminal processes stay fixed while placements change, as in the resource API.
const DAEMON = `#!${process.execPath}
const fs = require("node:fs");
const path = process.env.HOME + "/graph.json";
const graph = JSON.parse(fs.readFileSync(path, "utf8"));
let args = process.argv.slice(2);
fs.appendFileSync(process.env.HOME + "/calls.jsonl", JSON.stringify(args) + "\\n");
args.splice(0, 2);
args = args.filter(x => x !== "--json");
let expected;
if (args[0] === "--expected-revision") { expected = args[1]; args.splice(0, 2); }
const [noun, id, verb] = args;
const value = key => args[args.indexOf(key) + 1];
const emit = value => process.stdout.write(JSON.stringify(value) + "\\n");
if (noun === "session" && id === "current" && verb === "snapshot") { emit(graph); process.exit(0); }
if (expected !== undefined && (expected !== graph.session.revision || process.env.CONFLICT_TAB === id)) {
  process.stderr.write("revision.conflict\\n"); process.exit(7);
}
if (noun === "workspace" && id === "create") {
  if (process.env.CREATE_FAILURE === "1") { process.stderr.write(JSON.stringify({code:"operation.failed"})); process.exit(1); }
  const created = { id: "ws_created", name: value("--name"), index: graph.workspaces.length };
  graph.workspaces.push(created);
  graph.session.revision = (BigInt(graph.session.revision) + 1n).toString();
  fs.writeFileSync(path, JSON.stringify(graph));
  if (process.env.CONCURRENT_CREATE === "1") { process.stderr.write(JSON.stringify({code:"revision.conflict"})); process.exit(1); }
  emit({value: created}); process.exit(0);
}
const objects = graph[noun === "workspace" ? "workspaces" : noun + "s"];
const item = objects?.find(x => x.id === id);
if (!item) { process.stderr.write("selector.not_found\\n"); process.exit(2); }
if (verb === "rename" && ["workspace", "tab", "pane"].includes(noun)) {
  if (args.length !== 5 || args[3] !== "--name") process.exit(2);
  item.name = args[4];
} else if (noun === "tab" && verb === "move") {
  if (!["--workspace", "--screen", "--pane", "--index"].every(x => args.includes(x))) process.exit(2);
  if (!graph.panes.some(x => x.id === value("--pane") && x.screen_id === value("--screen"))) process.exit(2);
  item.pane_id = value("--pane"); item.index = Number(value("--index"));
} else if (noun === "pane" && verb === "swap") {
  const other = graph.panes.find(x => x.id === value("--other-pane"));
  if (!other) process.exit(2);
  [item.position, other.position] = [other.position, item.position];
} else if (noun === "pane" && verb === "split") {
  if (args[3] === "ratio") {
    if (!args.includes("--split") || !args.includes("--ratio")) process.exit(2);
    graph.ratio = Number(value("--ratio"));
  } else {
    if (!["--left", "--right", "--up", "--down"].includes(args[3])) process.exit(2);
    graph.panes.push({ id: "pane_created", screen_id: item.screen_id });
  }
} else if (noun === "workspace" && verb === "move") {
  if (args[3] !== "--index") process.exit(2);
  item.index = Number(args[4]);
} else if (verb === "focus") { graph.focused = id; }
else { process.stderr.write("unsupported grammar\\n"); process.exit(2); }
graph.session.revision = (BigInt(graph.session.revision) + 1n).toString();
fs.writeFileSync(path, JSON.stringify(graph));
emit({value: item, generation: process.env.RECEIPT_GENERATION ?? graph.session.generation, revision: graph.session.revision});
`;

async function fixture(peer: boolean) {
  const dir = mkdtempSync(join(tmpdir(), "cmux-topology-"));
  const shim = join(dir, "cmux");
  const daemon = join(dir, "cmux-tui");
  const graph = {
    session: { generation: "generation-1", revision: "9007199254740993" },
    workspaces: [{ id: "ws_task", name: "task", index: 0 }, { id: "ws_other", name: "other", index: 1 }],
    panes: [{ id: "pane_a", screen_id: "screen_a", position: 0 }, { id: "pane_b", screen_id: "screen_a", position: 1 }],
    tabs: [{ id: "tab_a", content_kind: "terminal", content_id: "term_agent", pane_id: "pane_a", index: 0 },
      { id: "tab_b", content_kind: "terminal", content_id: "term_agent", pane_id: "pane_b", index: 0 },
      { id: "tab_other", content_kind: "terminal", content_id: "term_other", pane_id: "pane_b", index: 1 }],
    terminals: [{ id: "term_agent", pid: 42 }, { id: "term_other", pid: 43 }],
  };
  writeFileSync(shim, GUEST_CMUX_SHIM);
  writeFileSync(daemon, DAEMON); chmodSync(daemon, 0o755);
  writeFileSync(join(dir, "graph.json"), JSON.stringify(graph));
  writeFileSync(join(dir, "calls.jsonl"), "");
  const socket = join(dir, "peer.sock");
  const server = createServer();
  if (peer) {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socket, resolve); });
    mkdirSync(join(dir, ".cmux/peers"), { recursive: true });
    mkdirSync(join(dir, ".cmux/peer-links"), { recursive: true });
    writeFileSync(join(dir, ".cmux/peers/peer.json"), "{}");
    writeFileSync(join(dir, ".cmux/peer-links/peer.sock-path"), socket);
    writeFileSync(join(dir, ".cmux/peer-links/peer.pid"), String(process.pid));
  }
  return {
    graph,
    read: () => JSON.parse(readFileSync(join(dir, "graph.json"), "utf8")),
    run: (args: string[], env = {}) => spawnSync("sh", [shim, ...(peer ? ["vm", args[0], args[1], "peer", ...args.slice(2)] : args)], {
      encoding: "utf8", timeout: 10_000,
      env: { NODE_ENV: "test", PATH: process.env.PATH, HOME: dir, CMUX_TUI_BIN: daemon, CMUX_TUI_TERMINAL_ID: "term_agent", ...env },
    }),
    calls: () => readFileSync(join(dir, "calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(x => JSON.parse(x)),
    cleanup: async () => { if (peer) await new Promise<void>(resolve => server.close(() => resolve())); rmSync(dir, { recursive: true, force: true }); },
    route: peer ? ["--socket", socket] : ["--session", "cloud"],
  };
}

for (const peer of [false, true]) describe(`guest topology (${peer ? "peer" : "local"})`, () => {
  test("rename and rearrange a workspace without restarting its terminals", async () => {
    const f = await fixture(peer);
    try {
      const name = "Review 日本語 $(touch nope)";
      for (const args of [
        ["workspace", "rename", "ws_task", name, "--json"],
        ["terminal", "rename", "term_agent", "Builder", "--json"],
        ["tab", "rename", "tab_b", "Logs"],
        ["tab", "move", "tab_b", "--workspace", "ws_task", "--screen", "screen_a", "--pane", "pane_a", "--index", "1"],
        ["pane", "swap", "pane_a", "--other-workspace", "ws_task", "--other-screen", "screen_a", "--other-pane", "pane_b"],
        ["pane", "resize", "pane_a", "--split", "split_a", "--ratio", "0.65"],
        ["pane", "split", "pane_a", "left"],
        ["workspace", "move", "ws_task", "--index", "1"],
        ["tab", "focus", "tab_b"],
      ]) {
        const run = f.run(args);
        expect(run.stderr).toBe(""); expect(run.status).toBe(0);
      }
      const state = f.read();
      expect(state.workspaces[0]).toMatchObject({ name, index: 1 });
      expect(state.tabs[0].name).toBe("Builder");
      expect(state.tabs[1]).toMatchObject({ name: "Logs", pane_id: "pane_a", index: 1 });
      expect(state.tabs[2].name).toBeUndefined();
      expect(state.panes.map((x: {id: string}) => x.id)).toContain("pane_created");
      expect(state.panes[0].position).toBe(1); expect(state.ratio).toBe(0.65);
      expect(state.focused).toBe("tab_b"); expect(state.terminals).toEqual(f.graph.terminals);
      expect(f.calls().every((c: string[]) => JSON.stringify(c.slice(0, 2)) === JSON.stringify(f.route))).toBe(true);
    } finally { await f.cleanup(); }
  });

  test("renames every placement with exact empty-name and UInt64 revision handling", async () => {
    const f = await fixture(peer);
    try {
      const run = f.run(["terminal", "rename", peer ? "term_agent" : "current", "", "--json"]);
      expect(run.status).toBe(0);
      expect(JSON.parse(run.stdout)).toMatchObject({terminal_id: "term_agent", tab_ids: ["tab_a", "tab_b"], name: "", revision: "9007199254740995"});
      expect(f.read().tabs.slice(0, 2).map((t: {name: string}) => t.name)).toEqual(["", ""]);
    } finally { await f.cleanup(); }
  });

  test("reports partial rename on conflict and never retries or changes unrelated terminals", async () => {
    const f = await fixture(peer);
    try {
      const run = f.run(["terminal", "rename", "term_agent", "Review"], { CONFLICT_TAB: "tab_b" });
      expect(run.status).toBe(1); expect(run.stderr).toContain("1 placement");
      expect(f.read().tabs.map((t: {name?: string}) => t.name)).toEqual(["Review", undefined, undefined]);
      expect(f.calls()).toHaveLength(3);
    } finally { await f.cleanup(); }
  });

  test("rejects missing targets, bad receipt generations, and surplus rename arguments", async () => {
    const f = await fixture(peer);
    try {
      expect(f.run(["terminal", "rename", "term_missing", "Review"]).status).toBe(1);
      expect(f.run(["tab", "rename", "tab_a", "Name", "surplus"]).status).toBe(2);
      const run = f.run(["terminal", "rename", "term_agent", "Review"], { RECEIPT_GENERATION: "restarted" });
      expect(run.status).toBe(1); expect(run.stderr).toContain("receipt");
      expect(f.read().tabs[1].name).toBeUndefined();
    } finally { await f.cleanup(); }
  });
});

for (const peer of [false, true]) test(`topology rejects invalid moves and preserves daemon syntax (${peer})`, async () => {
  const f = await fixture(peer);
  try {
    const before = f.read();
    const invalid = f.run(["tab", "move", "tab_a", "--workspace", "ws_task", "--screen", "screen_a", "--pane", "missing", "--index", "0"]);
    expect(invalid.status).toBe(2);
    expect(f.read()).toEqual(before);
    if (!peer) {
      expect(f.run(["tab", "tab_a", "rename", "--name", "Raw syntax"]).status).toBe(0);
      expect(f.read().tabs[0].name).toBe("Raw syntax");
    }
    const missing = f.run(["workspace", "rename", "ws_task"]);
    expect(missing.status).toBe(2);
    expect(missing.stderr).toContain("cmux workspace help");
  } finally { await f.cleanup(); }
});

test("topology help is localized and works before daemon installation", () => {
  const dir = mkdtempSync(join(tmpdir(), "cmux-topology-help-"));
  try {
    const shim = join(dir, "cmux"); writeFileSync(shim, GUEST_CMUX_SHIM);
    for (const noun of ["workspace", "pane", "tab", "terminal"]) {
      for (const args of [[noun, "--help"], ["vm", noun, "--help"]]) {
        const run = spawnSync("sh", [shim, ...args], {encoding: "utf8", timeout: 5_000,
          env: {NODE_ENV: "test", HOME: dir, PATH: process.env.PATH, CMUX_TUI_BIN: join(dir, "absent"), LC_ALL: "ja_JP.UTF-8"}});
        expect(run.status).toBe(0); expect(run.stdout).toContain("配置");
      }
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

describe("guest workspace reuse", () => {
  test.each([false, true])("local/peer reuse keeps exact names and uses revision-fenced creation (peer=%s)", async (peer) => {
    const f = await fixture(peer);
    try {
      const existing = f.run(["workspace", "new", "--name", "task", "--reuse", "--no-open", "--json"]);
      expect(existing.status).toBe(0);
      expect(JSON.parse(existing.stdout)).toMatchObject({value: {id: "ws_task"}, existing: true});
      const created = f.run(["workspace", "new", "--name", "new", "--reuse", "--json"]);
      expect(created.status).toBe(0);
      expect(JSON.parse(created.stdout)).toMatchObject({value: {id: "ws_created"}, existing: false});
      expect(f.calls().filter(call => call.includes("create"))[0]).toContain("--expected-revision");
      expect(f.read().workspaces.filter((workspace: {name: string}) => workspace.name === "new")).toHaveLength(1);
    } finally { await f.cleanup(); }
  });
  test("a concurrent creator is discovered after a revision conflict", async () => {
    const f = await fixture(false);
    try {
      const result = f.run(["workspace", "new", "--name", "raced", "--reuse", "--json"], {CONCURRENT_CREATE: "1"});
      expect(result.status).toBe(0);
      expect(JSON.parse(result.stdout)).toMatchObject({value: {name: "raced"}, existing: true});
      expect(f.calls().filter(call => call.includes("create"))).toHaveLength(1);
    } finally { await f.cleanup(); }
  });
  test("non-conflict failures never retry creation", async () => {
    const f = await fixture(false);
    try {
      const result = f.run(["workspace", "new", "--name", "failure", "--reuse"], {CREATE_FAILURE: "1"});
      expect(result.status).not.toBe(0);
      expect(f.calls().filter(call => call.includes("create"))).toHaveLength(1);
      expect(f.read().workspaces).toHaveLength(2);
    } finally { await f.cleanup(); }
  });
});
