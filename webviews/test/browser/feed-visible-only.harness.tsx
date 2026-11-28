// The real Feed page over the mock provider (`#n=10000`), for bench/cloud-feed-visible-only.bench.ts:
// the Inbox opens on the seed's edit request, whose diff attachment has N lines. The bench can have
// the detail draw again for an update of the item (its diff unchanged). `benchRowRenders` counts the
// diff lines that rendered since its last mark (test/support/mountedRowRenders.ts).
import { mountFeedPage } from "../../src/pages/feed/main";
import { MockFeedProvider, sampleFeed } from "../../src/pages/feed/mockProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Marks the open item read and back unread: the page reads the feed again, the diff the same. */
    benchChangeOne(index?: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const ITEM = "fi_codex_edit";
const diff = Array.from({ length: n }, (_, index) =>
  index % 40 === 0
    ? `@@ -${index},40 +${index},40 @@`
    : `${index % 3 === 0 ? "+" : index % 3 === 1 ? "-" : " "}    let value${index} = compute(${index}) // ${"x".repeat(index % 50)}`,
).join("\n");
const items = sampleFeed(Date.now()).map((item) =>
  item.id === ITEM
    ? {
        ...item,
        attachments: item.attachments?.map((attachment) => ({ ...attachment, text: diff, size: diff.length })),
      }
    : item,
);
const provider = new MockFeedProvider(items);
const store = mountFeedPage(document.getElementById("bench-root")!, provider, `#/inbox?item=${ITEM}`);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".feed-detail .feed-diff-line"));
let title = 0;
window.benchChangeOne = async () => {
  provider.items = provider.items.map((item) => (item.id === ITEM ? { ...item, title: `Edit ${++title}` } : item));
  await store.reload();
};
// Ready once the detail draws the diff.
const ready = new MutationObserver(() => {
  if (!document.querySelector(".feed-detail .feed-diff-line")) return;
  ready.disconnect();
  window.benchReady = true;
});
ready.observe(document.getElementById("bench-root")!, { childList: true, subtree: true });
