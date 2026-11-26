// Boots one chat history block (model.ts) on its host: it draws each block the host streams and,
// a frame after each one is drawn, answers `ready` with the revision and its height, so the host shows
// the page only once it painted (no stale or empty frame in the sidebar's gap). A click, the fold, Show
// More and a right click go back as calls naming the revision they were made on; the host checks them.
// main.tsx boots it; tests and the gallery mount it directly.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  NO_BLOCK,
  parseBlock,
  parseSlice,
  parseVisibleSlice,
  SIDEBAR_CHATS_PARTS,
  sliceSurface,
  SidebarChatsOps,
  type SidebarChatsBlock,
  type SidebarChatsSlice,
  type SidebarChatsStrings,
} from "./model";
import { SidebarChats } from "./SidebarChats";

export interface MountedSidebarChats {
  /** Draws one block (the host's stream calls this; tests and the gallery call it directly). */
  show(block: SidebarChatsBlock): void;
  /** Mounts only the rows near `slice` (the host's slice stream calls this). It windows only the block whose
   * revision it names: an older one is dropped, a newer one waits for exactly that block. */
  showSlice(slice: SidebarChatsSlice): void;
  /** The same from `cmux.page.visibleSlice` for `surface`: only the drawn block's surface windows it, and once one
   * arrives for a surface, `showSlice` (the old wire) no longer windows that surface's block. */
  showVisibleSlice(surface: string, slice: SidebarChatsSlice): void;
  /** The block drawn now (null before the first). */
  readonly block: SidebarChatsBlock | null;
  unmount(): void;
}

export interface MountOptions {
  makeRoot?: typeof createRoot;
  /** The frame after the commit (tests pass their own). */
  nextFrame?: (run: () => void) => () => void;
}

function animationFrame(run: () => void): () => void {
  if (typeof requestAnimationFrame !== "function") {
    const timer = setTimeout(run, 0);
    return () => clearTimeout(timer);
  }
  const frame = requestAnimationFrame(run);
  return () => cancelAnimationFrame(frame);
}

export function mountSidebarChats(
  root: HTMLElement,
  client: PageClient | null,
  strings: SidebarChatsStrings,
  options: MountOptions = {},
): MountedSidebarChats {
  const reactRoot = (options.makeRoot ?? createRoot)(root);
  const nextFrame = options.nextFrame ?? animationFrame;
  let block = NO_BLOCK;
  // The slice the drawn rows were windowed by: measured on the drawn block, or on an earlier drawn block
  // (it holds across blocks until the next one; the host sends one after each push).
  let slice: SidebarChatsSlice | null = null;
  // Slices naming a block not drawn yet, the latest per surface (null: the old wire, which names none); one windows
  // only a block with exactly its revision, if that comes next, and of its surface. Before its first block the page
  // hears both surfaces, so one slot for all would let the other surface's slice drop this page's own.
  const early = new Map<string | null, SidebarChatsSlice>();
  // The surfaces a `cmux.page.visibleSlice` slice arrived for: the old wire's slices no longer window their block.
  const generic = new Set<string>();
  // Whether a slice from `surface` (null: the old wire, which names none) may window a block of `part`.
  const windows = (surface: string | null, part: SidebarChatsBlock["part"]) =>
    surface === null ? !generic.has(sliceSurface(part)) : surface === sliceSurface(part);
  let cancelReady: (() => void) | null = null;

  const send = (op: string, params: Record<string, unknown>) => {
    if (!client || !block) return;
    void client.call(op, { revision: block.revision, ...params }).catch((error: unknown) => {
      console.error(`sidebar chats: ${op} failed`, error);
    });
  };

  // Made once: the memoized rows keep them across blocks (`send` reads the block drawn at the click).
  const onOpen = (chat: string) => send(SidebarChatsOps.open, { chat });
  const onFold = () => send(SidebarChatsOps.fold, {});
  const onMore = () => send(SidebarChatsOps.more, {});
  const onMenu = (chat: string, point: { x: number; y: number }) => send(SidebarChatsOps.menu, { chat, point });

  const render = () => {
    reactRoot.render(
      block ? (
        <SidebarChats
          block={block}
          slice={slice}
          strings={strings}
          onOpen={onOpen}
          onFold={onFold}
          onMore={onMore}
          onMenu={onMenu}
        />
      ) : null,
    );
  };

  /** One ready per drawn revision, a frame after the commit; a newer block in that frame supersedes it. */
  const scheduleReady = () => {
    cancelReady?.();
    cancelReady = null;
    if (!block) return;
    const { revision } = block;
    cancelReady = nextFrame(() => {
      cancelReady = null;
      if (!block || block.revision !== revision) return;
      const drawn = root.querySelector<HTMLElement>(".sc-block");
      const height = drawn ? Math.ceil(drawn.getBoundingClientRect().height) : 0;
      send(SidebarChatsOps.ready, { height });
    });
  };

  const show = (next: SidebarChatsBlock) => {
    // A block older than the one drawn (a reordered event) changes nothing.
    if (block && next.revision <= block.revision) return;
    block = next;
    // A slice sent ahead of this block windows it only if it names this block and its surface; every other is
    // dropped. At most one matches: a surface with a generic slice held is in `generic`, so the old wire's does not.
    for (const [surface, held] of early)
      if (held.revision === next.revision && windows(surface, next.part)) slice = held;
    early.clear();
    flushSync(render);
    scheduleReady();
  };

  const applySlice = (next: SidebarChatsSlice, surface: string | null) => {
    // A slice windows only the block it was measured on. One for a block not drawn yet waits for exactly
    // that block (`show`); one for an older block changes nothing.
    if (!block || next.revision > block.revision) {
      early.set(surface, next);
      return;
    }
    if (next.revision < block.revision) return;
    if (slice && slice.revision === next.revision && slice.top === next.top && slice.height === next.height) return;
    slice = next;
    // No ready: the slice changes which rows mount, never the block's height.
    flushSync(render);
  };

  // The old wire (`cmux.sidebarChats.slice`): it goes once the host that sends `cmux.page.visibleSlice` ships.
  const showSlice = (next: SidebarChatsSlice) => {
    // Ignored for a surface that has the generic stream; before a block, for any surface that has it.
    if (block ? generic.has(sliceSurface(block.part)) : generic.size > 0) return;
    applySlice(next, null);
  };

  const showVisibleSlice = (surface: string, next: SidebarChatsSlice) => {
    generic.add(surface);
    // The other block's surface (each block is its own page) windows nothing here.
    if (block && surface !== sliceSurface(block.part)) return;
    applySlice(next, surface);
  };

  flushSync(render);
  let stopped = false;
  let unsubscribe: (() => void) | undefined;
  if (client)
    void client
      .subscribe<unknown>(SidebarChatsOps.block, (data) => {
        const parsed = parseBlock(data);
        if (!stopped && parsed) show(parsed);
      })
      .then((stop) => (stopped ? stop() : (unsubscribe = stop)))
      .catch((error: unknown) => console.error("sidebar chats: no block stream", error));
  let unsubscribeSlice: (() => void) | undefined;
  if (client)
    void client
      .subscribe<unknown>(SidebarChatsOps.slice, (data) => {
        const parsed = parseSlice(data);
        if (!stopped && parsed) showSlice(parsed);
      })
      .then((stop) => (stopped ? stop() : (unsubscribeSlice = stop)))
      .catch((error: unknown) => {
        // A host without the slice stream (before it, or one that sends only `cmux.page.visibleSlice`).
        if (isPageError(error) && error.code === "cmux.protocol.unknown_op") return;
        console.error("sidebar chats: no slice stream", error);
      });
  // The page does not know its part until its first block, so it hears both surfaces; `showVisibleSlice` keeps
  // only its own block's.
  const unsubscribeVisible: Array<() => void> = [];
  if (client)
    for (const part of SIDEBAR_CHATS_PARTS)
      void client
        .subscribe<unknown>(
          SidebarChatsOps.visibleSlice,
          (data) => {
            const parsed = parseVisibleSlice(data);
            if (!stopped && parsed) showVisibleSlice(parsed.surface, parsed.slice);
          },
          { surface: sliceSurface(part) },
        )
        .then((stop) => (stopped ? stop() : unsubscribeVisible.push(stop)))
        .catch((error: unknown) => {
          // A host before the generic stream: the old wire windows the rows, or none does.
          if (isPageError(error) && error.code === "cmux.protocol.unknown_op") return;
          console.error("sidebar chats: no visible-slice stream", error);
        });
  return {
    show,
    showSlice,
    showVisibleSlice,
    get block() {
      return block;
    },
    unmount() {
      stopped = true;
      unsubscribe?.();
      unsubscribeSlice?.();
      unsubscribeVisible.splice(0).forEach((stop) => stop());
      cancelReady?.();
      reactRoot.unmount();
    },
  };
}
