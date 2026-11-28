// l10n-allow-file: bench fixture titles, not shipped UI.
// The real Stashed Tabs page over N stashed pages (`#n=10000`, in groups of ten), for
// bench/stash-page-visible-only.bench.ts: a stand-in owner that answers every list with all N and
// lets the bench change one member. `benchRowRenders` counts the rows that rendered since its last
// mark, read from the props React holds on each mounted row's own node, so the page carries no
// counter. (test/support/mountedRowRenders.ts reads the nearest component above the row instead;
// the rows before this change were inline in the page, so that component was the page itself.)
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/stash/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/stash/generated/strings.json";
import { StashPage } from "../../src/pages/stash/StashPage";
import { MockStashProvider } from "../../src/pages/stash/mockProvider";
import { StashStore } from "../../src/pages/stash/store";
import { UiProvider } from "../../src/ui/UiProvider";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th member's title and has the page read the list again. */
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const NOW = Date.UTC(2026, 10, 18, 12);
const PER_GROUP = 10;

const provider = new MockStashProvider(
  Array.from({ length: Math.ceil(n / PER_GROUP) }, (_, group) => ({
    id: `s${group}`,
    name: `Workspace ${group}`,
    created_at_ms: NOW - group * 60_000,
    members: Array.from({ length: Math.min(PER_GROUP, n - group * PER_GROUP) }, (_, index) => ({
      id: `m${index}`,
      kind: "tab" as const,
      url: `https://example.com/articles/${group}/${index}`,
      title: `Page ${group}.${index} about something worth reading again`,
    })),
  })),
);
const store = new StashStore(provider);
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(
  <UiProvider container={root}>
    <StashPage store={store} strings={strings} />
  </UiProvider>,
);
/** React's props object on a node: the same object until the element that made the node renders again. */
const hostProps = (node: Element) => {
  const key = Object.keys(node).find((name) => name.startsWith("__reactProps$"));
  return key ? (node as unknown as Record<string, unknown>)[key] : undefined;
};
let seen = new Set<unknown>();
window.benchRowRenders = {
  mark() {
    seen = new Set([...document.querySelectorAll(".stash-row")].map(hostProps));
  },
  since() {
    return [...document.querySelectorAll(".stash-row")].filter((row) => !seen.has(hostProps(row))).length;
  },
};
window.benchChangeOne = async (index) => {
  const group = provider.stashes[Math.floor(index / PER_GROUP)]!;
  const at = index % PER_GROUP;
  group.members[at] = { ...group.members[at]!, title: `Changed ${Date.now()}` };
  await store.reload();
};
void store.start().then(() => {
  window.benchReady = true;
});
