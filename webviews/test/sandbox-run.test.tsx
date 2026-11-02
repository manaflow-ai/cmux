// A Sandboxed send's state (hq#3367, sandboxRun.ts): the bridge call, the failure words' keys,
// and the tab's one send as the host holds it (SandboxTab). The chat view's tests are
// sandbox-run-view.test.tsx.
import { expect, test } from "bun:test";
import { runSandbox, sandboxAgent, sandboxFailureKey } from "../src/agent-session/acpmux/sandboxRun";

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

test("the chat's harness picks the sandbox agent; an unknown one leaves it to the server", () => {
  expect(sandboxAgent("claude-code")).toBe("claude");
  expect(sandboxAgent("codex")).toBe("codex");
  expect(sandboxAgent("gemini")).toBeUndefined();
  expect(sandboxAgent(undefined)).toBeUndefined();
});

test("only a refusal before any Run leaves the send to try again; a lost answer keeps it spent", async () => {
  const { sandboxRetryable } = await import("../src/agent-session/acpmux/sandboxRun");
  for (const code of ["not_signed_in", "labs_off", "run_sandbox_unavailable", "attachments", "agent"]) {
    expect(sandboxRetryable({ task: "go", state: "failed", code })).toBe(true);
  }
  for (const code of ["timeout", "unavailable", "http_500", "bad_response"]) {
    expect(sandboxRetryable({ task: "go", state: "failed", code })).toBe(false);
  }
  expect(sandboxRetryable({ task: "go", state: "running" })).toBe(false);
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

test("a read that never answers ends at its deadline", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const realSetTimeout = globalThis.setTimeout;
  // Deadlines fire at once here.
  globalThis.setTimeout = ((fn: () => void) => realSetTimeout(fn, 0)) as typeof setTimeout;
  try {
    const tab = new SandboxTab(
      () => new Promise(() => undefined),
      () => undefined,
    );
    await tab.read();
    expect(tab.host).toEqual({ kind: "unknown" });
    expect(tab.busy()).toBe(false);
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
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

test("a lost answer shows the run may still be going, then reads the host's truth", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const tab = new SandboxTab(
    async (method) => {
      if (method === "sandbox.run") throw { code: "unavailable" };
      return { task: "go", key: "k", reply: { ok: true, value: { receipt: { status: "succeeded", reply: "kept" } } } };
    },
    () => undefined,
  );
  tab.send("go", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "kept" } });
});

test("a newer read wins over an older one; the Run as pick is the person's alone", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const answers: ((value: unknown) => void)[] = [];
  const tab = new SandboxTab(
    () => new Promise((resolve) => answers.push(resolve)),
    () => undefined,
  );
  tab.setMode("persistent");
  const first = tab.read();
  const second = tab.read();
  answers[1]!({ task: "new", key: "k2", reply: { ok: true, value: { receipt: { status: "succeeded" } } } });
  answers[0]!({ task: "old", key: "k1", reply: { ok: false, error: { code: "not_signed_in" } } });
  await Promise.all([first, second]);
  expect(tab.view()).toMatchObject({ task: "new", state: "done" });
  expect(tab.mode).toBe("persistent");
});
test("a read that was out before a send can't overwrite the send's result", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let answerRead: (value: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run"
        ? Promise.resolve({ receipt: { status: "succeeded", reply: "mine" } })
        : new Promise((resolve) => (answerRead = resolve)),
    () => undefined,
  );
  const reading = tab.read();
  tab.send("go", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "mine" } });
  // The old read answers "no send" late: dropped.
  answerRead(null);
  await reading;
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "mine" } });
});

test("Sandboxed is offered only once a read said what the host holds for the tab", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let answer: () => Promise<unknown> = () => Promise.reject({ code: "native.not_connected" });
  const tab = new SandboxTab(
    () => answer(),
    () => undefined,
  );
  expect(tab.checked).toBe(false);
  await tab.read();
  expect(tab.checked).toBe(false);
  answer = () => Promise.resolve({});
  await tab.read();
  expect(tab.checked).toBe(true);
});

test("a read that fails after a lost answer keeps the tab's send spent", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const tab = new SandboxTab(
    (method) => Promise.reject({ code: method === "sandbox.run" ? "timeout" : "native.not_connected" }),
    () => undefined,
  );
  tab.setMode("sandboxed");
  tab.send("first", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  // The lost answer stays in view (it may hide a live Run), with Check again.
  expect(tab.unread).toBe(true);
  expect(tab.view()).toMatchObject({ task: "first", state: "failed", code: "timeout" });
  expect(tab.spent()).toBe(true);
  expect(tab.send("second", "claude")).toBe(false);
});

test("a send out holds a reload until its own answer, even once a read found the tab's receipt", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let refuse: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run"
        ? new Promise((_, reject) => (refuse = reject))
        : Promise.resolve({
            task: "first",
            key: "earlier",
            reply: { ok: true, value: { receipt: { status: "succeeded" } } },
          }),
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  tab.send("second", "claude");
  await tab.read();
  expect(tab.busy()).toBe(true);
  refuse({ code: "sandbox_spent" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.busy()).toBe(false);
  expect(restored).toEqual(["second"]);
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

test("the Run API's documented request refusals are retryable; a code merely shaped like one is not", async () => {
  const { sandboxRetryable } = await import("../src/agent-session/acpmux/sandboxRun");
  const failed = (code: string) => ({ task: "go", state: "failed" as const, code });
  for (const code of ["run_task_required", "run_agent_invalid", "run_invalid_request"]) {
    expect(sandboxRetryable(failed(code))).toBe(true);
  }
  for (const code of ["run_task_invalid", "run_model_required", "run_vm1_invalid", "run_task_failed", "unavailable"]) {
    expect(sandboxRetryable(failed(code))).toBe(false);
  }
});

test("a send the host refuses as holding another stays spent until a read says what it holds", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let read: (value: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run" ? Promise.reject({ code: "sandbox_busy" }) : new Promise((resolve) => (read = resolve)),
    () => undefined,
  );
  tab.setMode("sandboxed");
  tab.send("go", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.spent()).toBe(true);
  expect(tab.send("again", "claude")).toBe(false);
  read({});
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.spent()).toBe(false);
});

test("a bridge error or a malformed answer is unknown, with Check again", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const failing = (answer: () => Promise<unknown>) => new SandboxTab(answer, () => undefined);
  for (const code of ["native.not_connected", "native.invalid_request", "transport.timeout"]) {
    const tab = failing(() => Promise.reject({ code }));
    await tab.read();
    expect(tab.host).toEqual({ kind: "unknown" });
  }
  const malformed = failing(() => Promise.resolve({ running: true }));
  await malformed.read();
  expect(malformed.host).toEqual({ kind: "unknown" });
  const none = failing(() => Promise.resolve(null));
  await none.read();
  expect(none.host).toEqual({ kind: "none" });
});

test("a sandbox_spent refusal reads the host, which shows the tab's existing receipt", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  const tab = new SandboxTab(
    async (method) => {
      if (method === "sandbox.run") throw { code: "sandbox_spent" };
      return {
        task: "first",
        key: "k",
        reply: { ok: true, value: { receipt: { status: "succeeded", reply: "first" } } },
      };
    },
    (text) => restored.push(text),
  );
  tab.send("second", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(restored).toEqual(["second"]);
  expect(tab.view()).toMatchObject({ task: "first", state: "done", receipt: { reply: "first" } });
  expect(tab.send("third", "claude")).toBe(false);
});

test("a receipt the send confirmed stands: a read out while it ran can't replace it", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let finishSend: (value: unknown) => void = () => undefined;
  let failWait: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method, params) =>
      method === "sandbox.run"
        ? new Promise((resolve) => (finishSend = resolve))
        : params.wait
          ? new Promise((_, reject) => (failWait = reject))
          : Promise.resolve({ task: "go", key: "k", running: true }),
    () => undefined,
  );
  tab.send("go", "claude");
  // A reconnect reads while the send runs.
  const reading = tab.read();
  await new Promise((resolve) => setTimeout(resolve, 0));
  finishSend({ receipt: { status: "succeeded", reply: "mine" } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  failWait(new Error("bridge dropped"));
  await reading;
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "mine" } });
  expect(tab.spent()).toBe(true);
  // Later reads change nothing either.
  await tab.read();
  expect(tab.view()).toMatchObject({ state: "done", receipt: { reply: "mine" } });
});

test("a read never puts a prompt back or shows a refusal: recovery shows only what the host holds", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  const tab = new SandboxTab(
    async () => ({ task: "go", key: "k-1", reply: { ok: false, error: { code: "not_signed_in" } } }),
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  await tab.read();
  expect(tab.view()).toBeUndefined();
  expect(tab.mode).toBe("sandboxed");
  expect(restored).toEqual([]);
  expect(tab.spent()).toBe(false);
});
test("a read that ends the send's attempt retires its spinner, and the send's late answer is ignored", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let key = "";
  let refuse: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    async (method, params) => {
      if (method === "sandbox.run") {
        key = String(params.key);
        return new Promise((_, reject) => (refuse = reject));
      }
      return { task: "go", key, reply: { ok: false, error: { code: "not_signed_in" } } };
    },
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  tab.send("go", "claude");
  await tab.read();
  expect(tab.mine).toBeUndefined();
  expect(tab.busy()).toBe(false);
  expect(tab.view()).toBeUndefined();
  refuse({ code: "not_signed_in" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(restored).toEqual([]);
  expect(tab.view()).toBeUndefined();
});
test("a send refused after a read found the tab's receipt keeps the receipt and gives its prompt back", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let refuse: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run"
        ? new Promise((_, reject) => (refuse = reject))
        : Promise.resolve({
            task: "first",
            key: "earlier",
            reply: { ok: true, value: { receipt: { status: "succeeded", reply: "first" } } },
          }),
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  tab.send("second", "claude");
  await tab.read();
  expect(tab.view()).toMatchObject({ task: "first", state: "done" });
  refuse({ code: "sandbox_spent" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(restored).toEqual(["second"]);
  expect(tab.mine).toBeUndefined();
  expect(tab.view()).toMatchObject({ task: "first", state: "done", receipt: { reply: "first" } });
});

test("a refusal of the page's own send ends a running state a read saw, freeing the tab", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let refuse: (error: unknown) => void = () => undefined;
  let key = "";
  const tab = new SandboxTab(
    (method, params) => {
      if (method === "sandbox.run") {
        key = String(params.key);
        return new Promise((_, reject) => (refuse = reject));
      }
      return params.wait ? new Promise(() => undefined) : Promise.resolve({ task: "go", key, running: true });
    },
    () => undefined,
  );
  tab.setMode("sandboxed");
  tab.send("go", "claude");
  void tab.read();
  await new Promise((resolve) => setTimeout(resolve, 0));
  refuse({ code: "run_sandbox_unavailable" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toMatchObject({ state: "failed", code: "run_sandbox_unavailable" });
  expect(tab.busy()).toBe(false);
  expect(tab.spent()).toBe(false);
});

test("a refused send's prompt comes back once, from its own answer; a later read changes nothing", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let key = "";
  const tab = new SandboxTab(
    async (method, params) => {
      if (method === "sandbox.run") {
        key = String(params.key);
        throw { code: "not_signed_in" };
      }
      return { task: "go", key, reply: { ok: false, error: { code: "not_signed_in" } } };
    },
    (text) => restored.push(text),
  );
  tab.setMode("sandboxed");
  tab.send("go", "claude");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(restored).toEqual(["go"]);
  expect(tab.view()).toMatchObject({ state: "failed", code: "not_signed_in" });
  await tab.read();
  expect(restored).toEqual(["go"]);
  expect(tab.view()).toMatchObject({ state: "failed", code: "not_signed_in" });
  // Persistent clears it, and a read doesn't bring it back.
  tab.setMode("persistent");
  tab.setMode("sandboxed");
  await tab.read();
  expect(tab.view()).toBeUndefined();
  expect(restored).toEqual(["go"]);
});
test("a receipt a read finds while the send is unanswered ends the spinner and the reload hold", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let key = "";
  const tab = new SandboxTab(
    (method, params) => {
      if (method === "sandbox.run") {
        key = String(params.key);
        return new Promise(() => undefined);
      }
      return Promise.resolve({ task: "go", key, reply: { ok: true, value: { receipt: { status: "succeeded" } } } });
    },
    () => undefined,
  );
  tab.send("go", "claude");
  expect(tab.busy()).toBe(true);
  await tab.read();
  expect(tab.view()).toMatchObject({ state: "done" });
  expect(tab.busy()).toBe(false);
});

test("a send whose answer is lost while another attempt's receipt holds the tab gets its prompt back", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  const restored: string[] = [];
  let lose: (error: unknown) => void = () => undefined;
  const tab = new SandboxTab(
    (method) =>
      method === "sandbox.run"
        ? new Promise((_resolve, reject) => (lose = reject))
        : Promise.resolve({
            task: "older",
            key: "k-old",
            reply: { ok: true, value: { receipt: { status: "succeeded" } } },
          }),
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
    const tab = new SandboxTab(
      async () => ({ task: "go", key, running: true }),
      () => undefined,
    );
    await tab.read();
    expect(tab.host).toEqual({ kind: "unknown" });
    expect(tab.checked).toBe(false);
  }
});

test("a read that fails keeps the run the tab last knew in view, with Check again, and frees a reload", async () => {
  const { SandboxTab } = await import("../src/agent-session/acpmux/sandboxRun");
  let fail = false;
  const tab = new SandboxTab(
    (_method, params) =>
      fail
        ? Promise.reject({ code: "native.not_connected" })
        : params.wait
          ? new Promise(() => undefined)
          : Promise.resolve({ task: "go", key: "k", running: true }),
    () => undefined,
  );
  void tab.read();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.view()).toEqual({ task: "go", state: "running" });
  expect(tab.busy()).toBe(true);
  fail = true;
  await tab.read();
  expect(tab.unread).toBe(true);
  expect(tab.view()).toEqual({ task: "go", state: "running" });
  expect(tab.spent()).toBe(true);
  // No read is left to end the hold: the run stays shown, but a web update may reload.
  expect(tab.busy()).toBe(false);
  // Check again answers: the run holds a reload again.
  fail = false;
  void tab.read();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(tab.unread).toBe(false);
  expect(tab.busy()).toBe(true);
});
