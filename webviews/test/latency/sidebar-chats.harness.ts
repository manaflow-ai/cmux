// l10n-allow-file: latency harness fixture titles, not shipped UI.
// Latency harness page for the sidebar's chat history (src/pages/sidebar-chats): the shipped page over
// an in-page host (mock-host.ts, every call and subscription answering after `?hostDelay=`, 40 ms by
// default) that holds Earlier with `?n=` chats (500 by default) and answers as SidebarChatHistoryProvider
// does: a fold sends a block with no rows (folded) or every row (open), Show More sends the next 20 rows.
// With `?slice` the host also streams the part of the page in sight, one slice per frame after a scroll
// (the native host's slice stream); without it every loaded row mounts, as against a host before it.
// In the app the sidebar list scrolls the page; here the document does, so the page's own stylesheet's
// pinned document is unpinned.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/sidebar-chats/styles.css";
import { createPageClient } from "../../src/pages/shared/pageClient";
import { FIXTURE_STRINGS, fixtureBlock, fixtureRows } from "../../src/pages/sidebar-chats/fixtures";
import { SidebarChatsOps, type SidebarChatRow, type SidebarChatsBlock } from "../../src/pages/sidebar-chats/model";
import { mountSidebarChats, type MountedSidebarChats } from "../../src/pages/sidebar-chats/mount";
import { installMockHost } from "./mock-host";

declare global {
  interface Window {
    __latencySidebarChats: {
      /** Unmounts the page and boots it again on the same host: open-to-content. */
      reopen(): void;
      /** The host's next block retitles the `index`th chat (a rename arriving): returns the new title. */
      rename(index: number): string;
      /** Rows the page has mounted now. */
      mounted(): number;
      /** Chats the host has sent, and renames so far. */
      loaded(): number;
      renames(): number;
    };
  }
}

const query = new URLSearchParams(location.search);
const n = Number(query.get("n") ?? 500);
const withSlice = query.has("slice");
const style = document.createElement("style");
style.textContent = "html, body { overflow: auto !important; }";
document.head.append(style);

// Every loaded chat, as acpmux's Earlier window holds it; the block shows `shown` of them unless folded.
let all: SidebarChatRow[] = fixtureRows(n);
let shown = n;
let block: SidebarChatsBlock = fixtureBlock({ revision: 1, rows: all, tail: "more" });
let renames = 0;
let opens = 0;

const blockOf = (folded: boolean): SidebarChatsBlock => ({
  ...block,
  revision: block.revision + 1,
  folded,
  rows: folded ? [] : all.slice(0, shown),
});
const slice = () => ({ revision: block.revision, top: window.scrollY, height: window.innerHeight });
const initial: Record<string, unknown> = {};
Object.defineProperty(initial, SidebarChatsOps.block, { enumerable: true, get: () => block });
if (withSlice) Object.defineProperty(initial, SidebarChatsOps.slice, { enumerable: true, get: slice });

const push = (next: SidebarChatsBlock) => {
  block = next;
  host.emit(SidebarChatsOps.block, structuredClone(block));
  if (withSlice) sliceNextFrame();
};

const host = installMockHost(
  {
    [SidebarChatsOps.fold]: () => push(blockOf(!block.folded)),
    [SidebarChatsOps.more]: () => {
      all = [...all, ...fixtureRows(20, all.length)];
      shown = all.length;
      push(blockOf(false));
    },
    [SidebarChatsOps.open]: () => null,
    [SidebarChatsOps.menu]: () => null,
    [SidebarChatsOps.ready]: () => null,
  },
  withSlice ? [SidebarChatsOps.block, SidebarChatsOps.slice] : [SidebarChatsOps.block],
  initial,
);

let slicePending = false;
function sliceNextFrame() {
  if (slicePending) return;
  slicePending = true;
  requestAnimationFrame(() => {
    slicePending = false;
    host.emit(SidebarChatsOps.slice, slice());
  });
}
if (withSlice) {
  window.addEventListener("scroll", sliceNextFrame, { passive: true });
  window.addEventListener("resize", sliceNextFrame);
}

const root = document.getElementById("root")!;
const client = createPageClient();
let mounted: MountedSidebarChats = mountSidebarChats(root, client, FIXTURE_STRINGS);

window.__latencySidebarChats = {
  reopen() {
    mounted.unmount();
    mounted = mountSidebarChats(root, client, FIXTURE_STRINGS);
    document.documentElement.dataset.opens = String(++opens);
  },
  rename(index) {
    const title = `Renamed chat ${++renames}`;
    all = all.map((row, at) => (at === index ? { ...row, title } : row));
    push(blockOf(block.folded));
    return title;
  },
  mounted: () => root.querySelectorAll(".sc-row[data-chat]").length,
  loaded: () => all.length,
  renames: () => renames,
};
