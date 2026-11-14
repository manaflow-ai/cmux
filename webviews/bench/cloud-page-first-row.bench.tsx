// l10n-allow-file: bench fixture names, not shipped UI.
// The Cloud page's first machine row, from mount: the page opens with the list it kept last time (a
// storage holding the owner's earlier answer) and the owner answers every call after LATENCY ms (the
// page's bridge to the Cloud app server and on to the platform). Before the kept list, the first row
// waited for three serial answers (auth, the machine watch's subscribe, the list); with it, the first
// row is in the page's first frame and the owner's answer replaces it in place.
//   [LATENCY=ms] bun bench/cloud-page-first-row.bench.tsx [rounds=40]
// Prints p50 and p95 of mount-to-first-row (ms) and of mount-to-owner's-list (ms), one line each.
/// <reference types="bun" />
import { act } from "react";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const { createRoot } = await import("react-dom/client");
const { createStrings } = await import("../src/pages/shared/i18n");
const { CloudPage } = await import("../src/pages/cloud/CloudPage");
const table = (await import("../src/pages/cloud/generated/strings.json")).default;
const { MockCloudProvider, sampleMachines } = await import("../src/pages/cloud/mockProvider");
const { CloudStore } = await import("../src/pages/cloud/store");

const ROUNDS = Number(process.argv[2] ?? 40);
const LATENCY = Number(process.env.LATENCY ?? 150);
const strings = createStrings(table);

class SlowProvider extends MockCloudProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    await new Promise((resolve) => setTimeout(resolve, LATENCY));
    return super.call<R>(op, params);
  }
  override async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    await new Promise((resolve) => setTimeout(resolve, LATENCY));
    return super.subscribe<E>(stream, onEvent);
  }
}

class MemoryStorage {
  readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value);
  }
  removeItem(key: string): void {
    this.items.delete(key);
  }
}

// The list the page kept from its last open (machineCache.ts's key and shape).
const kept = new MemoryStorage();
kept.setItem(
  "cmux.cloud.machines.v1",
  JSON.stringify({ team: "team_personal", machines: sampleMachines(), revision: 1 }),
);
const ownerCount = sampleMachines().length;

async function round(): Promise<{ firstRow: number; owner: number }> {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const store = new CloudStore(new SlowProvider(), { cache: kept });
  const start = performance.now();
  let firstRow = -1;
  let owner = -1;
  await act(async () => root.render(<CloudPage store={store} strings={strings} />));
  for (;;) {
    const titles = [...element.querySelectorAll(".cloud-machine-title")].map((node) => node.textContent);
    const now = performance.now() - start;
    if (firstRow < 0 && titles.length > 0) firstRow = now;
    if (
      store.getSnapshot().connection === "connected" &&
      titles.length === ownerCount &&
      !store.getSnapshot().loading
    ) {
      owner = now;
      break;
    }
    if (now > 30_000) throw new Error("the page never showed the owner's list");
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 2));
    });
  }
  await act(async () => root.unmount());
  element.remove();
  return { firstRow, owner };
}

const pct = (values: number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.round(q * (sorted.length - 1)))];
};
const rows: Array<{ firstRow: number; owner: number }> = [];
await round(); // warm-up: module and JIT
for (let i = 0; i < ROUNDS; i++) rows.push(await round());
for (const key of ["firstRow", "owner"] as const) {
  const values = rows.map((row) => row[key]);
  console.log(
    `cloud_page.${key} latency=${LATENCY}ms rounds=${ROUNDS} p50=${pct(values, 0.5).toFixed(1)}ms p95=${pct(values, 0.95).toFixed(1)}ms`,
  );
}
process.exit(0);
