// A Sandboxed send's chat view (hq#3367): the chat shows the message, a spinner while the throwaway
// VM runs it, then its receipt: the reply first, then status, time, cost, artifacts and the VM's
// cleanup. The send's state is sandbox-run.test.tsx's.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { runSandbox } from "../src/agent-session/acpmux/sandboxRun";
import { SandboxRunView } from "../src/agent-session/acpmux/SandboxRunView";

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
  expect(text(markup)).not.toContain(t("sandbox.checkAgain"));
});

test("a running card whose newest read failed says so and offers Check again", () => {
  const markup = renderToStaticMarkup(
    <SandboxRunView run={{ task: "list the TODOs", state: "running" }} unread onCheckAgain={() => undefined} />,
  );
  expect(text(markup)).toContain(t("sandbox.running"));
  expect(text(markup)).toContain(t("sandbox.unchecked"));
  expect(text(markup)).toContain(t("sandbox.checkAgain"));
  expect(markup).toContain("cv-spinner");
  // A refusal that says the host holds another send offers it too once a read failed.
  const held = { task: "go", state: "failed" as const, code: "sandbox_busy" };
  const check = () => undefined;
  expect(text(renderToStaticMarkup(<SandboxRunView run={held} onCheckAgain={check} />))).not.toContain(
    t("sandbox.checkAgain"),
  );
  expect(text(renderToStaticMarkup(<SandboxRunView run={held} unread onCheckAgain={check} />))).toContain(
    t("sandbox.checkAgain"),
  );
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
