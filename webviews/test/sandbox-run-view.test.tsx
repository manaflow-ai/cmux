// A Sandboxed send's chat view (hq#3367): the chat shows the message, a spinner while the throwaway
// VM runs it, then its receipt: the reply first, then status, time, cost, artifacts and the VM's
// cleanup. The send's state is sandbox-run.test.tsx's.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { runSandbox } from "../src/agent-session/acpmux/sandboxRun";
import { SandboxRunView } from "../src/agent-session/acpmux/SandboxRunView";
import { actTurn, until } from "./support/until";

let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html>");
});
afterAll(() => dom.window.close());

const text = (markup: string) => {
  const box = dom.window.document.createElement("div");
  box.innerHTML = markup;
  return box.textContent?.replace(/\s+/g, " ").trim() ?? "";
};

test("running shows the message and a turning spinner, never a pulsing dot", () => {
  const markup = renderToStaticMarkup(<SandboxRunView run={{ task: "list the TODOs", state: "running" }} />);
  expect(text(markup)).toContain("list the TODOs");
  expect(text(markup)).toContain(t("sandbox.running"));
  expect(markup).toContain("cv-spinner");
  expect(markup).not.toContain("cv-spinner__dot");
  expect(text(markup)).not.toContain("Check again");
});

test("a running card whose newest read failed reads again on its own, with no Check again button", async () => {
  const markup = renderToStaticMarkup(
    <SandboxRunView run={{ task: "list the TODOs", state: "running" }} unread onCheckAgain={() => undefined} />,
  );
  expect(text(markup)).toContain(t("sandbox.running"));
  // Nothing at first: no failure words, no button (Leo, 2026-11-22: no vacuous "try again").
  expect(text(markup)).not.toContain("Couldn't check");
  expect(text(markup)).not.toContain("Check again");
  expect(markup).not.toContain("<button");
  expect(markup).toContain("cv-spinner");
  // A refusal that says the host holds another send has no button either way.
  const held = { task: "go", state: "failed" as const, code: "sandbox_busy" };
  const check = () => undefined;
  expect(text(renderToStaticMarkup(<SandboxRunView run={held} onCheckAgain={check} />))).not.toContain("Check again");
  expect(text(renderToStaticMarkup(<SandboxRunView run={held} unread onCheckAgain={check} />))).not.toContain(
    "Check again",
  );

  // Mounted, the card asks the host again by itself, and says Still checking once that has lasted
  // (the gallery's zero grace shows it at once).
  const window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  const scope = globalThis as Record<string, unknown>;
  const saved = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, scope[key]] as const);
  Object.assign(scope, { window, document: window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { setLastingGrace, LASTING_MS } = await import("../src/ui/lasting");
  setLastingGrace(0);
  let reads = 0;
  const root = createRoot(window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <SandboxRunView run={{ task: "list the TODOs", state: "running" }} unread onCheckAgain={() => reads++} />,
      ),
    );
    await act(async () => Promise.resolve());
    const shown = window.document.body.textContent ?? "";
    expect(shown).toContain(t("sandbox.stillChecking"));
    expect(window.document.querySelector("button")).toBeNull();
    await until(() => reads >= 1, actTurn);
    expect(reads).toBeGreaterThanOrEqual(1);
  } finally {
    await act(async () => root.unmount());
    setLastingGrace(LASTING_MS);
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    window.close();
  }
});

test("a succeeded receipt reads reply first, then status, time, cost, artifacts and VM destroyed", () => {
  const receipt = {
    status: "succeeded",
    exitCode: 0,
    reply: "3 TODOs found",
    artifacts: [{ name: "report.md", sizeBytes: 12 }],
    timings: { totalMs: 95_000, bootMs: 30_000 },
    cost: { vmSeconds: 95, estimateUsd: 0.0029 },
    cleanup: "destroyed",
  };
  const shown = text(renderToStaticMarkup(<SandboxRunView run={{ task: "go", state: "done", receipt }} />));
  const order = ["3 TODOs found", t("sandbox.succeeded"), "95.0", "0.0029", "report.md", t("sandbox.vmDestroyed")];
  const at = order.map((part) => shown.indexOf(part));
  expect(at.every((index) => index >= 0)).toBe(true);
  expect([...at].sort((a, b) => a - b)).toEqual(at);
});

test("a timed-out receipt says so in the chat's words (never the server's), an unmeasured cost says not measured, and a pending destroy shows", () => {
  const receipt = {
    status: "failed",
    timedOut: true,
    cost: { estimateUsd: null },
    cleanup: "pending",
  };
  const shown = text(renderToStaticMarkup(<SandboxRunView run={{ task: "go", state: "done", receipt }} />));
  for (const part of [t("sandbox.failed"), t("sandbox.timedOut"), t("sandbox.costUnknown"), t("sandbox.vmPending")]) {
    expect(shown).toContain(part);
  }
});

// #39022 review at a5563b2d, F2: a cleanup cmux gave up on says the VM is left to delete, never
// that its destroy is still pending.
test("an abandoned cleanup says the VM was not deleted, never that its destroy is pending", () => {
  const receipt = { status: "succeeded", cleanup: "abandoned" };
  const shown = text(renderToStaticMarkup(<SandboxRunView run={{ task: "go", state: "done", receipt }} />));
  expect(t("sandbox.vmAbandoned")).not.toBe("sandbox.vmAbandoned");
  expect(shown).toContain(t("sandbox.vmAbandoned"));
  expect(shown).not.toContain(t("sandbox.vmPending"));
});

test("a refusal is worded by its code; a failure that may hide a Run says so", async () => {
  const refused = await runSandbox(
    () => Promise.reject({ code: "run_sandbox_unavailable", message: "x" }),
    "go",
    undefined,
    "k",
  );
  expect(text(renderToStaticMarkup(<SandboxRunView run={refused} />))).toContain(t("sandbox.error.notEnabled"));
  const failed = await runSandbox(() => Promise.reject({ code: "http_500", message: "boom" }), "go", undefined, "k");
  // A 500 may hide a live Run: it says so rather than the host's words.
  expect(text(renderToStaticMarkup(<SandboxRunView run={failed} />))).toContain(t("sandbox.error.uncertain"));
  const calls: unknown[] = [];
  const done = await runSandbox(
    async (method, params) => (calls.push([method, params]), { receipt: { status: "succeeded" } }),
    "go",
    "claude",
    "k-1",
  );
  expect(done).toEqual({ task: "go", state: "done", receipt: { status: "succeeded" } });
  expect(calls).toEqual([["sandbox.run", { task: "go", key: "k-1", agent: "claude" }]]);
  expect(await runSandbox(async () => ({}), "go", undefined, "k")).toMatchObject({
    state: "failed",
    code: "bad_response",
  });
});

test("the page's own refusals (attachments, an agent a sandbox can't run) are worded", () => {
  for (const [code, key] of [
    ["attachments", "sandbox.error.attachments"],
    ["agent", "sandbox.error.agent"],
    ["timeout", "sandbox.error.timeout"],
  ] as const) {
    expect(text(renderToStaticMarkup(<SandboxRunView run={{ task: "go", state: "failed", code }} />))).toContain(
      t(key),
    );
  }
});

test("Sandboxed picked but not runnable now is refused with a way to send as Persistent", async () => {
  const { sandboxRetryable } = await import("../src/agent-session/acpmux/sandboxRun");
  const run = { task: "go", state: "failed" as const, code: "unavailable_now" };
  expect(sandboxRetryable(run)).toBe(true);
  let persistent = 0;
  const markup = renderToStaticMarkup(<SandboxRunView run={run} onPersistent={() => persistent++} />);
  expect(text(markup)).toContain(t("sandbox.error.notNow"));
  expect(text(markup)).toContain(t("sandbox.usePersistent"));
  expect(text(renderToStaticMarkup(<SandboxRunView run={{ ...run, code: "labs_off" }} />))).toContain(
    t("sandbox.error.labsOff"),
  );
  expect(persistent).toBe(0);
});

test("the host's one-send-per-tab refusals have their own words", async () => {
  const { sandboxRetryable } = await import("../src/agent-session/acpmux/sandboxRun");
  for (const code of ["sandbox_busy", "sandbox_spent"]) {
    expect(sandboxRetryable({ task: "go", state: "failed", code })).toBe(true);
    expect(text(renderToStaticMarkup(<SandboxRunView run={{ task: "go", state: "failed", code }} />))).toContain(
      t("sandbox.error.spent"),
    );
  }
});
