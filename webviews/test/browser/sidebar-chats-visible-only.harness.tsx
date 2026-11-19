// The real sidebar chats page over N Earlier rows (`#n=10000`), for bench/sidebar-chats-visible-only.bench.ts.
// In the app the page is as tall as its block and the sidebar list scrolls it; here the document scrolls it
// and a stand-in host streams the block and, like the native host, one slice per frame after a scroll
// ({revision, top, height}: the part of the page in the window). A page without the slice stream never
// subscribes, so it gets none. `benchRowRenders` counts the rows that rendered since its last mark, read
// from each mounted row's fiber (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/sidebar-chats/styles.css";
import { mountSidebarChats } from "../../src/pages/sidebar-chats/mount";
import { FIXTURE_STRINGS, fixtureBlock, fixtureRows } from "../../src/pages/sidebar-chats/fixtures";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Retitles the `index`th chat: the host's next block. */
    benchChangeOne(index: number): void;
    /** The host's age tick with no age label moved: the same rows in a new block. */
    benchTick(): void;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
// The page's own stylesheet pins the document (the sidebar list scrolls it in the app); the bench scrolls it.
const style = document.createElement("style");
style.textContent = "html, body { overflow: auto !important; }";
document.head.append(style);

let block = fixtureBlock({ revision: 1, rows: fixtureRows(n) });
const listeners = new Map<string, (data: unknown) => void>();
const wire = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const sendSlice = () =>
  listeners.get("cmux.sidebarChats.slice")?.({
    revision: block.revision,
    top: window.scrollY,
    height: window.innerHeight,
  });
let slicePending = false;
const sliceNextFrame = () => {
  if (slicePending) return;
  slicePending = true;
  requestAnimationFrame(() => {
    slicePending = false;
    sendSlice();
  });
};
const push = (next: typeof block) => {
  block = next;
  listeners.get("cmux.sidebarChats.block")?.(wire(block));
  sliceNextFrame();
};

const client = {
  call: async () => undefined,
  subscribe: async (stream: string, onEvent: (data: unknown) => void) => {
    listeners.set(stream, onEvent);
    if (stream === "cmux.sidebarChats.block") queueMicrotask(() => onEvent(wire(block)));
    if (stream === "cmux.sidebarChats.slice") queueMicrotask(sendSlice);
    return () => listeners.delete(stream);
  },
  handle: () => () => {},
};

mountSidebarChats(document.getElementById("root")!, client as never, FIXTURE_STRINGS);
window.addEventListener("scroll", sliceNextFrame, { passive: true });
window.addEventListener("resize", sliceNextFrame);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".sc-row[data-chat]"));
window.benchChangeOne = (index) =>
  push({
    ...block,
    revision: block.revision + 1,
    rows: block.rows.map((row, at) => (at === index ? { ...row, title: `Changed ${block.revision}` } : row)),
  });
window.benchTick = () => push({ ...block, revision: block.revision + 1 });
const settle = () =>
  document.querySelector(".sc-row[data-chat]") ? (window.benchReady = true) : requestAnimationFrame(settle);
requestAnimationFrame(settle);
