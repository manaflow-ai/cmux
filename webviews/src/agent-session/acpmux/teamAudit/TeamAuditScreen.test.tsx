// l10n-allow-file: test fixtures, not shipped UI.
// History > Team asks again on its own when a read fails (autoRetry.ts): no Try again button, the
// status reads as loading, and the table lands when a later read answers (Leo, 2026-11-22: "vacuous
// decisions like that should be just done").
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { importWithDom } from "../../../../test/support/importWithDom";
const { translate } = await importWithDom(() => import("../i18n"));
const { TeamAuditScreen } = await importWithDom(() => import("./TeamAuditScreen"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function until(done: () => boolean, ms = 4_000) {
  const end = Date.now() + ms;
  while (!done()) {
    if (Date.now() > end) throw new Error("timed out waiting");
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

const totals = {
  inputTokens: 100,
  outputTokens: 20,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  cacheHitRate: 0,
  turns: 3,
  toolCalls: 4,
  wallMs: 60_000,
  sessions: 1,
};
const ok = {
  status: "ok",
  audit: {
    scope: "team",
    range: { since: "2026-10-11", until: "2026-11-09" },
    groupBy: "person",
    totals,
    rows: [{ key: "ada", ...totals }],
  },
};

test("a failed read is asked again on its own, with no Try again, and the table lands", async () => {
  const replies: unknown[] = [{ status: "failed", message: "cmux-platform refused (503)" }, ok];
  let calls = 0;
  const load = async () => {
    calls++;
    return replies.shift() ?? ok;
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<TeamAuditScreen load={load} now={Date.UTC(2026, 10, 9, 15)} />);
  });
  await until(() => calls >= 1);
  // The failure reads as loading, and offers no button to ask again.
  expect(container.querySelector(".cst-status")?.textContent).toBe(translate("ledger.loading"));
  expect([...container.querySelectorAll("button")].map((node) => node.textContent)).not.toContain(
    translate("ledger.retry"),
  );
  await until(() => container.querySelector(".tma-table") !== null);
  expect(calls).toBe(2);
  expect(container.querySelector(".tma-table")?.textContent).toContain("ada");
});

test("an older acpmux is not asked again: it says so", async () => {
  let calls = 0;
  const load = async () => {
    calls++;
    throw { code: -32601, message: "Method not found" };
  };
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<TeamAuditScreen load={load} now={Date.UTC(2026, 10, 9, 15)} />);
  });
  // The older-acpmux answer is final: the screen says so and does not ask again.
  await until(() => container.querySelector(".cst-status")?.textContent === translate("teamAudit.older"));
  expect(calls).toBe(1);
});
