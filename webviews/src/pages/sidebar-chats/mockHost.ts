// An in-memory chat history host for the browser dev loop (`/sidebar-chats/?mock`), the gallery and
// the tests: it streams a fixture block and answers the calls as the native host does (Show More lists
// the next rows, the header folds Earlier), recording each one. Given a slice, it streams that too, after
// each block as the native host does; without one it has no slice stream, as a host before it.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { fixtureBlock, fixtureRows } from "./fixtures";
import { SidebarChatsOps, type SidebarChatsBlock, type SidebarChatsSlice } from "./model";

export class MockSidebarChatsHost implements PageClient {
  readonly calls: { op: string; params: Record<string, unknown> }[] = [];
  block: SidebarChatsBlock;
  /** The visible part of the page (its revision follows the block's). */
  slice: Omit<SidebarChatsSlice, "revision"> | null;
  private listener?: (data: SidebarChatsBlock, seq: number) => void;
  private sliceListener?: (data: SidebarChatsSlice, seq: number) => void;
  private seq = 0;

  constructor(block: SidebarChatsBlock = fixtureBlock(), slice: Omit<SidebarChatsSlice, "revision"> | null = null) {
    this.block = block;
    this.slice = slice;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    const body = (params ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params: body });
    switch (op) {
      case SidebarChatsOps.fold:
        this.update({ folded: !this.block.folded });
        break;
      case SidebarChatsOps.more:
        if (this.block.tail === "more")
          this.update({ rows: [...this.block.rows, ...fixtureRows(3, this.block.rows.length)] });
        break;
      case SidebarChatsOps.open:
      case SidebarChatsOps.menu:
      case SidebarChatsOps.ready:
        break;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
    return undefined as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === SidebarChatsOps.slice && this.slice) {
      this.sliceListener = onEvent as (data: SidebarChatsSlice, seq: number) => void;
      queueMicrotask(() => this.sendSlice());
      return () => (this.sliceListener = undefined);
    }
    if (stream !== SidebarChatsOps.block) throw pageError("cmux.protocol.unknown_op", stream);
    this.listener = onEvent as (data: SidebarChatsBlock, seq: number) => void;
    queueMicrotask(() => this.listener?.(this.block, ++this.seq));
    return () => (this.listener = undefined);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  private update(change: Partial<SidebarChatsBlock>) {
    this.block = { ...this.block, ...change, revision: this.block.revision + 1 };
    this.listener?.(this.block, ++this.seq);
    this.sendSlice();
  }

  private sendSlice() {
    if (this.slice) this.sliceListener?.({ ...this.slice, revision: this.block.revision }, ++this.seq);
  }
}
