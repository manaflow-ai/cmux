import { DurableObject } from "cloudflare:workers";
import { type MemoResult, MemoryService, type MemoryView } from "../memory-service.ts";
import type { Env } from "./env.ts";

/**
 * One chief's memory (plans/cmux-next/chief.md section 4). The object is the
 * single writer; every method runs to completion before the next, and writes
 * commit in one storage transaction.
 */
export class MemoryDO extends DurableObject<Env> {
  private readonly service: MemoryService;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    this.service = new MemoryService(
      (query, ...params) => sql.exec(query, ...params).toArray() as never,
      (fn) => ctx.storage.transactionSync(fn),
    );
  }

  memo(argv: Array<string>, options: { key?: string; files?: Record<string, string> } = {}): MemoResult {
    return this.service.memo(argv, options);
  }

  note(texts: Array<string>, key?: string): { first: number; count: number } | { error: string } {
    return this.service.note(texts, key);
  }

  nap(block: string, text: string, key?: string): MemoResult {
    return this.service.nap(block, text, key);
  }

  view(): MemoryView {
    return this.service.view();
  }

  setTimeZone(tz: string): { tz: string } {
    this.service.setTimeZone(tz);
    return { tz };
  }
}
