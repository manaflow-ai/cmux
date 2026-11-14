// Boots one chat history block (model.ts) on its host: it draws each block the host streams and,
// a frame after each one is drawn, answers `ready` with the revision and its height, so the host shows
// the page only once it painted (no stale or empty frame in the sidebar's gap). A click, the fold, Show
// More and a right click go back as calls naming the revision they were made on; the host checks them.
// main.tsx boots it; tests and the gallery mount it directly.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import type { PageClient } from "../shared/pageClient";
import { NO_BLOCK, parseBlock, SidebarChatsOps, type SidebarChatsBlock, type SidebarChatsStrings } from "./model";
import { SidebarChats } from "./SidebarChats";

export interface MountedSidebarChats {
  /** Draws one block (the host's stream calls this; tests and the gallery call it directly). */
  show(block: SidebarChatsBlock): void;
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
  let cancelReady: (() => void) | null = null;

  const send = (op: string, params: Record<string, unknown>) => {
    if (!client || !block) return;
    void client.call(op, { revision: block.revision, ...params }).catch((error: unknown) => {
      console.error(`sidebar chats: ${op} failed`, error);
    });
  };

  const render = () => {
    reactRoot.render(
      block ? (
        <SidebarChats
          block={block}
          strings={strings}
          onOpen={(chat) => send(SidebarChatsOps.open, { chat })}
          onFold={() => send(SidebarChatsOps.fold, {})}
          onMore={() => send(SidebarChatsOps.more, {})}
          onMenu={(chat, point) => send(SidebarChatsOps.menu, { chat, point })}
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
    flushSync(render);
    scheduleReady();
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
  return {
    show,
    get block() {
      return block;
    },
    unmount() {
      stopped = true;
      unsubscribe?.();
      cancelReady?.();
      reactRoot.unmount();
    },
  };
}
