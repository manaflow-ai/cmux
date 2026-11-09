// l10n-allow-file: test fixtures (sample sessions), not shipped UI.
// Costs' Export (ledger/LedgerScreen.tsx) writes every session of the range, reading again at
// acpmux's most (5,000) when the page holds only the top ones. A range with more sessions than
// that still exports, and says so: the status reads "Exported 5,000 of 6,001 sessions" beside
// Saved, and the JSON says `truncated` with `sessionsTotal` (the cmux#39335 review's F1).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import { LedgerScreen } from "../src/agent-session/acpmux/ledger/LedgerScreen";
import { LEDGER_EXPORT_LIMIT, type LedgerExportKind } from "../src/agent-session/acpmux/ledger/ledgerModel";

const NOW = 1_800_000_000_000;
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  class FakeResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const row = (index: number) => ({
  costUsd: 1,
  harnessCostUsd: 1,
  turns: 1,
  sessions: 1,
  sessionId: `s${index}`,
  title: `Session ${index}`,
  models: [],
  pullRequests: [],
});

/// A range of `total` sessions; a read returns at most `limit` of them.
function ledger(total: number) {
  return async (params: Record<string, unknown>) => ({
    priceTable: { version: "2026-11-08", currency: "USD" },
    range: { since: params.since, until: params.until },
    totals: { costUsd: total, harnessCostUsd: total, turns: total, sessions: total },
    rows: Array.from({ length: Math.min(total, Number(params.limit)) }, (_, index) => row(index)),
    rollups: {},
  });
}

async function exportJson(total: number) {
  const container = installDom();
  const reads: number[] = [];
  const files: { text: string; kind: LedgerExportKind }[] = [];
  const load = ledger(total);
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <LedgerScreen
        load={async (params) => {
          reads.push(Number(params.limit));
          return load(params);
        }}
        openSession={() => {}}
        save={async (text, _name, kind) => {
          files.push({ text, kind });
          return "saved";
        }}
        now={NOW}
      />,
    );
  });
  await act(async () => undefined);
  const document = container.ownerDocument;
  const button = [...container.querySelectorAll<HTMLElement>("button")].find(
    (each) => each.getAttribute("aria-label") === translate("ledger.export"),
  )!;
  expect(button).toBeDefined();
  await act(async () => button.click());
  await act(async () => undefined);
  const json = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === translate("ledger.export.json"),
  );
  expect(json).toBeDefined();
  await act(async () => json!.click());
  await act(async () => undefined);
  await act(async () => undefined);
  const status = container.querySelector("output.cst-copied")?.textContent ?? "";
  return { reads, files, status };
}

test("a range past acpmux's most exports what it can and says how many are missing", async () => {
  const { reads, files, status } = await exportJson(6001);
  // The page's read, then the export's at acpmux's most.
  expect(reads).toEqual([200, LEDGER_EXPORT_LIMIT]);
  expect(files).toHaveLength(1);
  const body = JSON.parse(files[0]!.text);
  expect(body.rows).toHaveLength(5000);
  expect(body.truncated).toBe(true);
  expect(body.sessionsTotal).toBe(6001);
  expect(status).toContain(translate("ledger.export.saved"));
  expect(status).toContain(translate("ledger.export.partial", { shown: "5,000", total: "6,001" }));
});

test("a range acpmux returns whole says Saved and nothing more", async () => {
  const { reads, files, status } = await exportJson(300);
  expect(reads).toEqual([200, LEDGER_EXPORT_LIMIT]);
  const body = JSON.parse(files[0]!.text);
  expect(body.rows).toHaveLength(300);
  expect(body.truncated).toBe(false);
  expect(body.sessionsTotal).toBe(300);
  expect(status).toBe(translate("ledger.export.saved"));
});
