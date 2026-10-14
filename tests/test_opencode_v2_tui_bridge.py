#!/usr/bin/env python3
"""Focused behavioral coverage for the OpenCode V2 per-TUI bridge."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    fixture = json.loads((ROOT / "tests/fixtures/opencode-v2-multi-tui.json").read_text())
    if not (ROOT / "node_modules/solid-js/package.json").is_file():
        print("FAIL: run bun install --frozen-lockfile before the OpenCode bridge test")
        return 1
    source = r'''
const { fixture, packageDir } = JSON.parse(process.env.CMUX_OPENCODE_V2_HARNESS);
const fs = await import("node:fs/promises");
const net = await import("node:net");
const path = await import("node:path");
const source = await fs.readFile(path.join(packageDir, "tui.js"), "utf8");
const { batch, createSignal } = await import("solid-js");
const mod = await import(path.join(packageDir, "tui.js"));
const serverMod = await import(path.join(packageDir, "index.js"));
if (typeof serverMod.default?.server !== "function") throw new Error("missing inert V2 server entrypoint");
const serverCleanup = await serverMod.default.setup({});
if (typeof serverCleanup !== "function") throw new Error("legacy server setup did not return a cleanup function");
serverCleanup();
const makeContext = (name) => {
  const spec = fixture.tuis[name];
  return {
    ui: {
      router: { current: () => spec.route },
      tabs: { enabled: () => true, list: () => spec.tabs.map((id) => ({ sessionID: id })) },
    },
    data: { session: { root: (id) => fixture.roots[id] || id } },
  };
};
if (!mod.sessionBelongsToTUI(makeContext("a"), "child-a")) throw new Error("TUI A lost its own session");
if (mod.sessionBelongsToTUI(makeContext("a"), "child-b")) throw new Error("TUI A claimed TUI B session");
const closed = { ui: { router: { current: () => fixture.starterClosed.route }, tabs: { enabled: () => true, list: () => [] } }, data: { session: { root: (id) => fixture.roots[id] || id } } };
if (mod.sessionBelongsToTUI(closed, "child-a")) throw new Error("closed starter surface retained ownership");
// A parent OpenCode's capture is inherited by an OpenCode it starts.
const parentLaunchArgv = Buffer.from("/parent/opencode\0-s\0parent-session\0", "utf8").toString("base64");
const dispatchEnvironment = { CMUX_SURFACE_ID: "surface-a", CMUX_WORKSPACE_ID: "workspace-a", CMUX_OPENCODE_HOOKS_DISABLED: "", CMUX_AGENT_LAUNCH_KIND: "opencode", CMUX_AGENT_LAUNCH_EXECUTABLE: "/parent/opencode", CMUX_AGENT_LAUNCH_ARGV_B64: parentLaunchArgv };
let spawnCalls = 0;
let spawnOptions;
const fakeSpawn = (_command, _args, options) => {
  spawnCalls++;
  spawnOptions = options;
  return { stdin: { end() {}, on() { return this; } }, on() { return this; }, unref() {} };
};
if (!mod.dispatchSessionHook("stop", { session_id: "opencode-child-a", cwd: "/tmp" }, fakeSpawn, dispatchEnvironment)) throw new Error("session admission was skipped");
if (spawnCalls !== 1) throw new Error("session admission did not use async spawn");
if (source.includes("spawnSync")) throw new Error("shared bridge still uses synchronous spawn");
if (spawnOptions?.env?.CMUX_AGENT_LAUNCH_KIND !== "opencode") throw new Error("session admission dropped launch kind");
if (!spawnOptions?.env?.CMUX_AGENT_LAUNCH_EXECUTABLE) throw new Error("session admission dropped launch executable");
if (!spawnOptions?.env?.CMUX_AGENT_LAUNCH_ARGV_B64) throw new Error("session admission dropped launch argv");
if (spawnOptions.env.CMUX_AGENT_LAUNCH_ARGV_B64 === parentLaunchArgv) throw new Error("session admission reused a parent OpenCode launch capture");

const socketPath = "/tmp/cmux-opencode-v2-" + process.pid + ".sock";
try { await fs.unlink(socketPath); } catch (_) {}
const observed = [];
const observedWaiters = [];
const waitForObserved = (predicate) => {
  const existing = observed.find(predicate);
  if (existing) return Promise.resolve(existing);
  return new Promise((resolve) => observedWaiters.push({ predicate, resolve }));
};
const delayedResponses = new Map();
let holdNextResponse = false;
const server = net.createServer((connection) => {
  connection.unref();
  connection.setEncoding("utf8");
  connection.on("error", () => {});
  connection.on("data", (chunk) => {
    for (const line of chunk.split("\n").filter(Boolean)) {
      const frame = JSON.parse(line);
      const event = frame.params.event;
      observed.push(event);
      for (let index = observedWaiters.length - 1; index >= 0; index--) {
        const waiter = observedWaiters[index];
        if (!waiter.predicate(event)) continue;
        observedWaiters.splice(index, 1);
        waiter.resolve(event);
      }
      if (frame.params.wait_timeout_seconds === 0) continue;
      const decision = event.hook_event_name === "PermissionRequest"
        ? { kind: "permission", mode: "once" }
        : event.hook_event_name === "ExitPlanMode"
          ? { kind: "exit_plan", mode: "deny", feedback: "please revise" }
          : { kind: "question", selections: ["yes"] };
      const response = () => {
        if (!connection.destroyed) connection.write(JSON.stringify({ result: { request_id: event._opencode_request_id, status: "resolved", decision } }) + "\n");
      };
      if (holdNextResponse) {
        delayedResponses.set(event._opencode_request_id, response);
        holdNextResponse = false;
      } else {
        response();
      }
    }
  });
});
await new Promise((resolve) => server.listen(socketPath, resolve));

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
const repliesA = { permission: deferred(), form: deferred(), question: deferred(), routeForm: deferred(), plan: deferred(), feedback: deferred() };
const repliesB = { permission: deferred() };
const makeLive = (name, environment, replies) => {
  const live = makeContext(name);
  live.location = { directory: `/tmp/${name}` };
  const [route, setRoute] = createSignal(live.ui.router.current());
  const [tabs, setTabs] = createSignal(live.ui.tabs.list());
  live.ui.router.current = route;
  live.ui.tabs.list = tabs;
  live.setRoute = setRoute;
  live.setTabs = setTabs;
  live.data.listen = (callback) => { live.emit = callback; return () => {}; };
  live.client = {
    permission: { reply: async (value) => { replies.permission?.resolve(value); } },
    session: {
      update: async () => {},
      prompt: async (value) => live.promptError ? { error: "prompt unavailable" } : (replies.feedback?.resolve(value), undefined),
      synthetic: async (value) => { replies.feedback?.resolve(value); },
    },
    _client: {
      post: async (request) => {
        if (request.url === "/question/{requestID}/reply") {
          replies.question?.resolve({ requestID: request.path.requestID, answers: request.body.answers });
        }
      },
    },
  };
  live.data.session.form = { reply: async (value, location) => {
    const target = value.formID === "form-route" ? replies.routeForm : value.formID === "form-plan" ? replies.plan : replies.form;
    target?.resolve({ value, location });
  } };
  live.environment = environment;
  live.promptError = false;
  return live;
};
const liveA = makeLive("a", { CMUX_SOCKET_PATH: socketPath, CMUX_SURFACE_ID: "surface-a", CMUX_WORKSPACE_ID: "workspace-a", CMUX_OPENCODE_HOOKS_DISABLED: "1" }, repliesA);
const liveB = makeLive("b", { CMUX_SOCKET_PATH: socketPath, CMUX_SURFACE_ID: "surface-b", CMUX_WORKSPACE_ID: "workspace-b", CMUX_OPENCODE_HOOKS_DISABLED: "1" }, repliesB);
const cleanupA = await mod.createCMUXTUIBridge(liveA, { environment: liveA.environment });
const cleanupB = await mod.createCMUXTUIBridge(liveB, { environment: liveB.environment });

// OpenCode can publish the restored session before the TUI has committed its
// route/tab state. The session-start event must survive that startup race so
// cmux can record the binding used by the next workspace restore.
const routeA = liveA.ui.router.current();
const tabsA = liveA.ui.tabs.list();
liveA.setRoute({ type: "home" });
liveA.setTabs([]);
liveA.emit({ details: { type: "session.created", data: { sessionID: "child-a", location: { directory: "/tmp/a" } } } });
// No subsequent service event or invented route callback: only a real Solid
// signal publishes readiness for an otherwise idle restored session.
liveA.setRoute(routeA);
await Promise.race([
  waitForObserved((event) => event.hook_event_name === "SessionStart" && event.session_id === "opencode-child-a"),
  new Promise((_, reject) => setTimeout(() => reject(new Error("idle restored session-start was dropped at route readiness")), 2000)),
]);
liveA.setTabs(tabsA);

// A non-start service event can arrive inside the same batch as the route
// commit, before Solid runs its observer. It must preserve the queued start.
liveA.setRoute({ type: "home" });
liveA.setTabs([]);
liveA.emit({ details: { type: "session.created", data: { sessionID: "child-status" } } });
batch(() => {
  liveA.setRoute({ type: "session", sessionID: "child-status" });
  liveA.emit({ details: { type: "session.status", data: { sessionID: "child-status", status: { type: "busy" } } } });
});
await waitForObserved((event) => event.hook_event_name === "SessionStart" && event.session_id === "opencode-child-status");

// Ending the queued session in that batch must cancel it before the observer
// gets a chance to flush it. Assert the normalized ID sent to the actual socket.
liveA.setRoute({ type: "home" });
liveA.emit({ details: { type: "session.created", data: { sessionID: "child-stale" } } });
batch(() => {
  liveA.setRoute({ type: "session", sessionID: "child-stale" });
  liveA.emit({ details: { type: "session.deleted", data: { sessionID: "child-stale" } } });
});
await waitForObserved((event) => event.hook_event_name === "SessionEnd" && event.session_id === "opencode-child-stale");
if (observed.some((event) => event.session_id === "opencode-child-stale" && event.hook_event_name === "SessionStart")) throw new Error("ended queued session-start was replayed");
liveA.setRoute(routeA);
liveA.setTabs(tabsA);
liveA.emit({ details: { type: "session.updated", data: { sessionID: "child-a", info: { id: "child-a", time: { archived: false } } } } });
// OpenCode 1.19 reports a failure before the idle status and idle marker.
// The failure must win the lifecycle race; the later idle forms are duplicates.
liveA.emit({ details: { type: "session.error", data: { sessionID: "child-a", error: { name: "UnknownError", data: { message: "provider failed" } } } } });
liveA.emit({ details: { type: "session.status", data: { sessionID: "child-a", status: "idle" } } });
liveA.emit({ details: { type: "session.idle", data: { sessionID: "child-a" } } });
liveB.emit({ details: { type: "session.execution.succeeded", data: { sessionID: "child-b" } } });
liveA.emit({ details: { type: "permission.asked", data: { sessionID: "child-a", id: "perm-a", action: "edit", resources: ["/tmp/a/file"] } } });
liveB.emit({ details: { type: "permission.asked", data: { sessionID: "child-a", id: "perm-wrong", action: "edit" } } });
const permissionA = await Promise.race([repliesA.permission.promise, new Promise((_, reject) => setTimeout(() => reject(new Error("permission reply timed out")), 2000))]);
if (permissionA.requestID !== "perm-a" || permissionA.reply !== "once" || permissionA.decision !== undefined) throw new Error("permission reply used the wrong TUI contract");
const permissionFrame = observed.find((event) => event._opencode_request_id === "perm-a");
if (permissionFrame?.tool_input?.action !== "edit" || permissionFrame?.tool_input?.resources?.[0] !== "/tmp/a/file") throw new Error("permission request details were dropped from the Feed frame");
liveA.emit({ details: { type: "permission.asked", data: { permission: {
  sessionID: "child-a", id: "perm-nested", action: "shell", resources: ["/tmp/a/script"],
  metadata: { command: "make test" }, always: ["shell"], save: true, source: "tool",
  message: "Run the build?", tool: { name: "bash" },
} } } });
const nestedFrame = await waitForObserved((event) => event._opencode_request_id === "perm-nested");
if (nestedFrame?.tool_input?.action !== "shell"
  || nestedFrame?.tool_input?.resources?.[0] !== "/tmp/a/script"
  || nestedFrame?.tool_input?.metadata?.command !== "make test"
  || nestedFrame?.tool_input?.always?.[0] !== "shell"
  || nestedFrame?.tool_input?.save !== true
  || nestedFrame?.tool_input?.source !== "tool"
  || nestedFrame?.tool_input?.message !== "Run the build?"
  || nestedFrame?.tool_input?.tool?.name !== "bash") {
  throw new Error("nested permission request details were dropped from the Feed frame");
}

liveA.emit({ details: { type: "form.created", data: { form: { sessionID: "child-a", id: "form-a", fields: [{ key: "choice", type: "string", options: [{ value: "yes-value", label: "yes" }] }] } } } });
const formA = await Promise.race([repliesA.form.promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`form reply timed out (${JSON.stringify(observed)})`)), 2000))]);
if (formA.value.sessionID !== "child-a" || formA.value.formID !== "form-a" || formA.value.answer.choice !== "yes-value") throw new Error("form reply was not mapped to its owning TUI");

liveA.emit({ details: { type: "question.asked", data: { sessionID: "child-a", id: "question-a", questions: [{ id: "choice", question: "Continue?", options: [{ label: "yes" }] }] } } });
const questionA = await Promise.race([repliesA.question.promise, new Promise((_, reject) => setTimeout(() => reject(new Error("legacy question reply timed out")), 2000))]);
if (questionA.requestID !== "question-a" || JSON.stringify(questionA.answers) !== JSON.stringify([["yes"]])) throw new Error("legacy question reply used the wrong TUI contract");

liveA.promptError = true;
liveA.emit({ details: { type: "form.created", data: { form: { sessionID: "child-a", id: "form-plan", title: "Build Agent", fields: [{ key: "decision", type: "string", question: "Plan at /tmp/plan.md is complete.", options: [{ value: "yes", label: "Yes" }, { value: "no", label: "No" }] }] } } } });
const planA = await Promise.race([repliesA.plan.promise, new Promise((_, reject) => setTimeout(() => reject(new Error("plan form reply timed out")), 2000))]);
if (planA.value.formID !== "form-plan" || planA.value.answer.decision !== "no") throw new Error("plan exit form used the wrong reply path");
const feedbackA = await Promise.race([repliesA.feedback.promise, new Promise((_, reject) => setTimeout(() => reject(new Error("plan feedback timed out")), 2000))]);
if (feedbackA.sessionID !== "child-a" || feedbackA.text?.resume !== undefined || feedbackA.resume !== false || typeof feedbackA.text !== "string") throw new Error("plan feedback used the wrong prompt contract");

liveA.emit({ details: { type: "session.inbox.enqueued", data: { sessionID: "child-a", item: { type: "user", payload: { text: "hello from v2" } } } } });
liveA.emit({ details: { type: "session.text.ended", data: { sessionID: "child-a", text: "assistant preamble" } } });

holdNextResponse = true;
liveA.emit({ details: { type: "form.created", data: { form: { sessionID: "child-a", id: "form-route", fields: [{ key: "choice", type: "string", options: [{ value: "yes-value", label: "yes" }] }] } } } });
await waitForObserved((event) => event._opencode_request_id === "form-route");
liveA.setRoute(fixture.starterClosed.route);
delayedResponses.get("form-route")?.();
const routeForm = await Promise.race([repliesA.routeForm.promise, new Promise((_, reject) => setTimeout(() => reject(new Error("route-change form reply timed out")), 2000))]);
if (routeForm.value.formID !== "form-route" || routeForm.value.answer.choice !== "yes-value") throw new Error("resolved TUI reply was dropped after route change");

liveB.emit({ details: { type: "session.updated", data: { sessionID: "child-b", info: { id: "child-b", time: { archived: true } } } } });

const beforeClosed = observed.length;
liveA.emit({ details: { type: "permission.asked", data: { sessionID: "child-a", id: "perm-closed", action: "edit" } } });
await new Promise((resolve) => setImmediate(resolve));
if (observed.length !== beforeClosed) throw new Error("closed starter surface retained Feed ownership");

await waitForObserved((event) => event.hook_event_name === "SessionStart");
await waitForObserved((event) => event.hook_event_name === "Stop");
const sessionStart = observed.find((event) => event.hook_event_name === "SessionStart");
const stop = observed.find((event) => event.hook_event_name === "Stop" && event.session_id === "opencode-child-b");
const childALifecycle = observed.filter((event) => event.session_id === "opencode-child-a"
  && ["SessionStart", "Stop"].includes(event.hook_event_name));
if (childALifecycle.filter((event) => event.hook_event_name === "SessionStart").length !== 1) throw new Error("session.updated reopened the OpenCode session");
if (childALifecycle.filter((event) => event.hook_event_name === "Stop").length !== 1) throw new Error("OpenCode failure-first lifecycle event was lost or duplicated");
if (!childALifecycle.some((event) => event.hook_event_name === "Stop" && event.is_error === true && event.error === "provider failed")) throw new Error("OpenCode session.error did not preserve an error completion");
if (sessionStart?.surface_id !== "surface-a" || sessionStart?.workspace_id !== "workspace-a") throw new Error("Feed event was routed to the wrong surface");
if (sessionStart?.cwd !== "/tmp/a") throw new Error("V2 session location was dropped from Feed telemetry");
if (stop?.surface_id !== "surface-b" || stop?.workspace_id !== "workspace-b") throw new Error("second TUI Feed event was routed to the first surface");
const prompt = observed.find((event) => event.hook_event_name === "UserPromptSubmit");
if (prompt?.tool_input?.prompt !== "hello from v2" || prompt?.context?.lastUserMessage !== "hello from v2") throw new Error("V2 inbox prompt was dropped from Feed context");
const sessionEnd = observed.find((event) => event.hook_event_name === "SessionEnd" && event.session_id === "opencode-child-b");
if (!sessionEnd) {
  await waitForObserved((event) => event.hook_event_name === "SessionEnd" && event.session_id === "opencode-child-b");
}
if (observed.find((event) => event.hook_event_name === "SessionEnd" && event.session_id === "opencode-child-b")?.surface_id !== "surface-b") throw new Error("archived session was not ended on its owning TUI");
if (observed.some((event) => event._opencode_request_id === "perm-wrong")) throw new Error("TUI B accepted a session owned by TUI A");

// A prompt queued during a running turn is admitted mid-turn and promoted
// after the stop. Both turns publish exactly one Stop; the repeated idle
// forms, a late failure and a shutdown interruption publish none.
liveA.setRoute({ type: "session", sessionID: "child-queue" });
const queueEvents = [
  ["session.status", { sessionID: "child-queue", status: { type: "busy" } }],
  ["session.next.prompt.admitted", { sessionID: "child-queue", messageID: "queued-m2" }],
  ["session.status", { sessionID: "child-queue", status: "idle" }],
  ["session.idle", { sessionID: "child-queue" }],
  ["session.error", { sessionID: "child-queue", error: { message: "late failure" } }],
  ["session.next.prompted", { sessionID: "child-queue", messageID: "queued-m2" }],
  ["session.execution.succeeded", { sessionID: "child-queue" }],
  ["session.status", { sessionID: "child-queue", status: { type: "busy" } }],
  ["session.execution.interrupted", { sessionID: "child-queue", reason: "shutdown" }],
  ["session.deleted", { sessionID: "child-queue" }],
];
for (const [type, data] of queueEvents) liveA.emit({ details: { type, data } });
await waitForObserved((event) => event.hook_event_name === "SessionEnd" && event.session_id === "opencode-child-queue");
const queueStops = observed.filter((event) => event.session_id === "opencode-child-queue" && event.hook_event_name === "Stop");
if (queueStops.length !== 2 || queueStops.some((event) => event.is_error)) throw new Error(`queued prompt turns published ${JSON.stringify(queueStops)}`);
liveA.setRoute(routeA);

// A bridge that never owns a queued session must release its expiry timer on
// disposal, rather than retaining the entire TUI context until the TTL elapses.
const expiryTimers = new Set();
const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
globalThis.setTimeout = (...args) => { const timer = nativeSetTimeout(...args); expiryTimers.add(timer); return timer; };
globalThis.clearTimeout = (timer) => { expiryTimers.delete(timer); nativeClearTimeout(timer); };
liveA.emit({ details: { type: "session.created", data: { sessionID: "never-owned" } } });
cleanupA();
const leakedTimers = expiryTimers.size;
for (const timer of expiryTimers) nativeClearTimeout(timer);
globalThis.setTimeout = nativeSetTimeout;
globalThis.clearTimeout = nativeClearTimeout;
if (leakedTimers) throw new Error("disposed TUI retained pending session-start timers");
cleanupB();
server.closeAllConnections?.();
await new Promise((resolve) => server.close(resolve));
console.log("PASS");
'''
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-v2-package-") as package:
        package_dir = Path(package)
        (package_dir / "index.js").write_text((ROOT / "Resources/opencode-plugin.js").read_text())
        (package_dir / "tui.js").write_text((ROOT / "Resources/opencode-tui-plugin.js").read_text())
        (package_dir / "node_modules").symlink_to(ROOT / "node_modules", target_is_directory=True)
        (package_dir / "harness.mjs").write_text(source)
        env = os.environ.copy()
        env["CMUX_OPENCODE_V2_HARNESS"] = json.dumps({"packageDir": str(package_dir), "fixture": fixture})
        result = subprocess.run([node, "--conditions=browser", str(package_dir / "harness.mjs")], cwd=ROOT, env=env, text=True, capture_output=True, check=False, timeout=20)
    if result.returncode:
        print("FAIL: OpenCode V2 TUI bridge harness")
        print(result.stdout)
        print(result.stderr)
        return 1
    print(result.stdout.strip() or "PASS: OpenCode V2 TUI bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
