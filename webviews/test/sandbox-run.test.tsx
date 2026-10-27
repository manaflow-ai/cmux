// A Sandboxed send's state (hq#3367, sandboxRun.ts): the bridge call, the failure words' keys,
// and the tab's one send as the host holds it (SandboxTab): the core cases; the rest are in the
// tests PR stacked on this one. The chat view's tests are sandbox-run-view.test.tsx.
import { expect, test } from "bun:test";
import { runSandbox, sandboxFailureKey } from "../src/agent-session/acpmux/sandboxRun";

test("the bridge call answers the receipt alone, or the host's code; never rejects", async () => {
  const calls: unknown[] = [];
  const done = await runSandbox(
    async (method, params) => (calls.push([method, params]), { receipt: { status: "succeeded" }, runId: "run-1" }),
    "go",
    "codex",
    "k",
  );
  expect(calls).toEqual([["sandbox.run", { task: "go", key: "k", agent: "codex" }]]);
  expect(done).toEqual({ task: "go", state: "done", receipt: { status: "succeeded" } });
  expect(await runSandbox(async () => ({}), "go", undefined, "k")).toMatchObject({ code: "bad_response" });
  expect(await runSandbox(() => Promise.reject({ code: "not_signed_in" }), "go", undefined, "k")).toMatchObject({
    code: "not_signed_in",
  });
  expect(await runSandbox(() => Promise.reject(new Error("x")), "go", undefined, "k")).toMatchObject({
    code: "unavailable",
  });
});

test("each code the chat words has a string key; any other has none (a generic line)", () => {
  expect(sandboxFailureKey("run_sandbox_unavailable")).toBe("sandbox.error.notEnabled");
  expect(sandboxFailureKey("unavailable")).toBe("sandbox.error.uncertain");
  expect(sandboxFailureKey("sandbox_spent")).toBe("sandbox.error.spent");
  expect(sandboxFailureKey("unavailable_now")).toBe("sandbox.error.notNow");
  expect(sandboxFailureKey("provider_vm_abc123")).toBeUndefined();
});

test("the tab renders what the host says: a running send, then its receipt", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let finish: (value: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (_method, params) =>
      params.wait
        ? new Promise((resolve) => (finish = resolve))
        : Promise.resolve({ task: "go", key: "k", running: true }),
    () => undefined,
  );
  const reading = tab.read();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toEqual({ task: "go", state: "running" });
  expect(tab.busy()).toBe(true);
  expect(tab.spent()).toBe(true);
  finish({ task: "go", key: "k", reply: { ok: true, value: { receipt: { status: "succeeded", reply: "done" } } } });
  await reading;
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "done" } });
  expect(tab.busy()).toBe(false);
  // One paid send per tab: no second.
  expect(tab.send("again", "claude")).toBe(false);
});

test("a refusal before any Run gives the prompt back and leaves the tab free to send", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  const tab = new SandboxTab(
    async () => {
      throw { code: "not_signed_in" };
    },
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  expect(tab.send("go", "claude")).toBe(true);
  expect(tab.view()).toEqual({ task: "go", state: "running" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toMatchObject({ state: "failed", code: "not_signed_in" });
  expect(restored).toEqual(["go"]);
  expect(tab.spent()).toBe(false);
  expect(tab.send("go", "claude")).toBe(true);
});

test("only the receipt fields the chat shows are kept; a value that is no receipt is bad_response", async () => {
  const done = await runSandbox(
    async () => ({
      receipt: {
        runId: "run-7",
        status: "succeeded",
        exitCode: 0,
        reply: "ok",
        error: "vm-abc failed",
        image: { id: "img" },
        timings: { totalMs: 9, createdAt: "t" },
        cost: { estimateUsd: 0.01, vcpus: 2 },
        artifacts: [{ name: "a.md", digest: "sha256:x", sizeBytes: 3 }],
      },
    }),
    "go",
    undefined,
    "k",
  );
  expect(done).toEqual({
    task: "go",
    state: "done",
    receipt: {
      status: "succeeded",
      exitCode: 0,
      reply: "ok",
      timings: { totalMs: 9 },
      cost: { estimateUsd: 0.01 },
      artifacts: [{ name: "a.md", sizeBytes: 3 }],
    },
  });
  expect(await runSandbox(async () => ({ receipt: ["x"] }), "go", undefined, "k")).toMatchObject({
    code: "bad_response",
  });
});

test("a send whose answer is lost while another attempt's receipt holds the tab gets its prompt back", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let lose: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run"
        ? new Promise((_resolve, reject) => (lose = reject))
        : Promise.resolve({ task: "older", key: "k-old", reply: { ok: true, value: { receipt: { status: "succeeded" } } } }),
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  expect(tab.send("current", "claude")).toBe(true);
  // A reconnect's read finds an older attempt's receipt while this send is out.
  await tab.read();
  expect(tab.view()).toMatchObject({ state: "done", task: "older" });
  // This send's own answer is lost: the host held the older one, so it refused this send.
  lose({ code: "timeout" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(restored).toEqual(["current"]);
  expect(tab.busy()).toBe(false);
});

test("the only documented request refusals free the tab; a host read with no attempt key is unknown", async () => {
  const { SandboxTab, sandboxRetryable } = await import("../src/agent-session/acpmux/sandboxRun");
  expect(sandboxRetryable({ task: "go", state: "failed", code: "run_image_invalid" })).toBe(true);
  for (const code of ["run_vm_deadbeef_invalid", "run_task_invalid", "unavailable"]) {
    expect(sandboxRetryable({ task: "go", state: "failed", code })).toBe(false);
  }
  for (const key of [undefined, ""]) {
    const tab = new SandboxTab(async () => ({ task: "go", key, running: true }), () => undefined);
    await tab.read();
    expect(tab.host).toEqual({ kind: "unknown" });
    expect(tab.checked).toBe(false);
  }
});
