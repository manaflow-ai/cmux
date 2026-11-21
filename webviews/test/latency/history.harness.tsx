// Latency harness page for History (src/pages/history): the shipped page over the in-memory mock
// provider with `?entries=N` entries (default 1000, the page's PAGE_LIMIT), every call answering
// after the host delay (`?hostDelay=`, default 40 ms), as the app's bridge does. `mount()` opens a
// fresh page (a new store, a new root), as opening the History tab does; `unmount()` closes it.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/transientMaterial";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/history/styles.css";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/history/generated/strings.json";
import { HistoryPage } from "../../src/pages/history/HistoryPage";
import { MockHistoryProvider } from "../../src/pages/history/mockProvider";
import { HistoryStore } from "../../src/pages/history/store";
import type { HistoryEntry, HistoryKind } from "../../src/pages/history/types";
import { UiProvider, languageDirection } from "../../src/ui/UiProvider";
import { hostDelay } from "./mock-host";

const params = new URLSearchParams(location.search);
const count = Number(params.get("entries") ?? 1000);
const delay = hostDelay();
const KINDS: HistoryKind[] = ["page", "command", "agent", "location", "closed"];
const now = Date.now();

function entry(index: number): HistoryEntry {
  const kind = KINDS[index % KINDS.length]!;
  const at = now - index * 37 * 60_000;
  const base = { id: `${kind}:local:${index}`, kind, at_ms: at, available: true };
  switch (kind) {
    case "page":
      return {
        ...base,
        title: `Docs page ${index}`,
        url: `https://example${index % 40}.test/docs/${index}`,
        detail: `example${index % 40}.test/docs/${index}`,
      };
    case "command":
      return {
        ...base,
        title: `cargo test -p crate${index % 17}`,
        command: `cargo test -p crate${index % 17}`,
        cwd: `/home/dev/code/repo${index % 9}`,
        exit_code: index % 7 === 0 ? 1 : 0,
        detail: `/home/dev/code/repo${index % 9}`,
      };
    case "agent":
      return {
        ...base,
        title: `Fix the flaky test number ${index}`,
        session_id: `s-${index}`,
        provider: "claude",
        cwd: `/home/dev/code/repo${index % 9}`,
        detail: `repo${index % 9}`,
      };
    case "location":
      return {
        ...base,
        title: `repo${index % 9}`,
        cwd: `/home/dev/code/repo${index % 9}`,
        workspace: `Workspace ${index % 5}`,
        detail: `/home/dev/code/repo${index % 9}`,
      };
    default:
      return {
        ...base,
        title: `Closed tab ${index}`,
        closed_kind: "browser_tab",
        workspace: `Workspace ${index % 5}`,
        detail: `Workspace ${index % 5}`,
      };
  }
}

class DelayedProvider extends MockHistoryProvider {
  override async call<R>(op: string, callParams: unknown): Promise<R> {
    // fixed-wait: the mock host's answer delay (the harness's "host" latency), not a wait for a state.
    // fixed-wait: the mock host's answer delay (the harness's "host" latency), not a wait for a state.
    await new Promise((resolve) => setTimeout(resolve, delay));
    return super.call<R>(op, callParams);
  }
}

const entries = Array.from({ length: count }, (_, index) => entry(index));
const strings = createStrings(table);
const host = document.getElementById("root")!;
let root: Root | undefined;

const history = {
  mount() {
    history.unmount();
    const store = new HistoryStore(new DelayedProvider(entries.map((item) => ({ ...item }))));
    root = createRoot(host);
    root.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <HistoryPage store={store} strings={strings} />
      </UiProvider>,
    );
  },
  unmount() {
    root?.unmount();
    root = undefined;
  },
};
(window as Window & { __latencyHistory?: typeof history }).__latencyHistory = history;
history.mount();
