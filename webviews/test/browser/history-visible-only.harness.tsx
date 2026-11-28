// l10n-allow-file: bench fixture titles, not shipped UI.
// The real History page over N entries (`#n=10000`), for bench/history-page-visible-only.bench.ts: a
// stand-in daemon that answers every list with all N, past the page's own limit, and lets the bench
// change one entry. `benchRowRenders` counts the rows that rendered since its last mark, read from
// each mounted row's fiber (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/history/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/history/generated/strings.json";
import { HistoryPage } from "../../src/pages/history/HistoryPage";
import { MockHistoryProvider } from "../../src/pages/history/mockProvider";
import { HistoryStore } from "../../src/pages/history/store";
import { HistoryOps, type HistoryListResult } from "../../src/pages/history/types";
import { UiProvider } from "../../src/ui/UiProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th entry's title and has the page read the list again. */
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const NOW = Date.UTC(2026, 10, 18, 12);

class ManyEntries extends MockHistoryProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== HistoryOps.list) return super.call<R>(op, params);
    return { entries: this.entries.map((entry) => ({ ...entry })), revision: 1 } satisfies HistoryListResult as R;
  }
}

const provider = new ManyEntries(
  Array.from({ length: n }, (_, index) => ({
    id: `page:local:${index}`,
    kind: "page" as const,
    at_ms: NOW - index * 60_000,
    title: `Page ${index} about something worth reading again`,
    detail: `https://example.com/articles/${index}`,
    url: `https://example.com/articles/${index}`,
    available: true,
  })),
  () => NOW,
);
const store = new HistoryStore(provider, { newKey: () => "k" });
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(
  <UiProvider container={root}>
    <HistoryPage store={store} strings={strings} now={() => NOW} />
  </UiProvider>,
);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".history-row"));
window.benchChangeOne = async (index) => {
  provider.entries[index] = { ...provider.entries[index]!, title: `Changed ${Date.now()}` };
  await store.reload();
};
void store.start().then(() => {
  window.benchReady = true;
});
