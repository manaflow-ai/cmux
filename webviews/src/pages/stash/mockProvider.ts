// An in-memory stash owner for the browser dev loop, the gallery and tests. It is not the backend:
// the daemon's stash store keeps stashes and the app restores and deletes them. The mock keeps
// only enough (list, import, restore, delete, change events) to drive the page.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { LINK_CLOSED, MockPageStreams } from "../shared/pageStreams";
import { StashOps, type StashImportGroup, type StashRecord } from "./types";

export interface MockCall {
  op: string;
  params: unknown;
}

export class MockStashProvider implements PageClient {
  stashes: StashRecord[];
  readonly calls: MockCall[] = [];
  /** Set to make every call reject as if the host went away. */
  offline = false;
  /** What the app's Undo toast answers a delete: true deletes, false is Undo. */
  undo = false;
  /** A delete waits on this (the toast) when set. */
  toast?: Promise<void>;
  readonly page = new MockPageStreams();
  private readonly subs = new Set<(data: unknown, seq: number) => void>();
  private seq = 0;
  private next = 1;
  private revision = 0;

  constructor(stashes: StashRecord[] = sampleStashes(Date.now())) {
    this.stashes = stashes;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    const args = (params ?? {}) as {
      stash?: string;
      members?: string[];
      groups?: StashImportGroup[];
      idempotency_key?: string;
    };
    switch (op) {
      case StashOps.list:
        return structuredClone(this.stashes) as R;
      case StashOps.import: {
        let imported = 0;
        let skipped = 0;
        for (const group of args.groups ?? []) {
          const tabs = group.tabs.filter((tab) => /^https?:\/\//.test(tab.url));
          skipped += group.tabs.length - tabs.length;
          imported += tabs.length;
          if (!tabs.length) continue;
          this.stashes.unshift({
            id: `import-${this.next++}`,
            created_at_ms: Date.now(),
            members: tabs.map((tab, index) => ({ id: `m${index}`, kind: "tab", ...tab })),
          });
        }
        if (typeof args.idempotency_key !== "string" || !args.idempotency_key) {
          throw Object.assign(new Error("mutations require idempotency_key"), { code: "cmux.validation.invalid" });
        }
        this.changed();
        this.revision += 1;
        // The daemon's mutation reply (resource_router.rs mutation_result).
        return {
          value: { stash_ids: [], imported_tabs: imported, skipped_tabs: skipped },
          generation: 1,
          revision: String(this.revision),
          replayed: false,
        } as R;
      }
      case StashOps.restore:
        this.drop(args.stash, args.members);
        return { ok: true } as R;
      case StashOps.delete: {
        await this.toast;
        if (this.undo) return { deleted: false } as R;
        this.drop(args.stash, args.members);
        return { deleted: true } as R;
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    if (this.offline) throw pageError(LINK_CLOSED, "disconnected", true);
    if (stream !== StashOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = onEvent as (data: unknown, seq: number) => void;
    this.subs.add(listener);
    return () => this.subs.delete(listener);
  }

  /** The page serves no ops to its host; kept for the interface. */
  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** A stash another client made (a tab menu's Save and Close, the CLI). */
  push(stash: StashRecord): void {
    this.stashes.unshift(stash);
    this.changed();
  }

  private drop(stash: string | undefined, members: string[] | undefined): void {
    this.stashes = this.stashes.flatMap((record) => {
      if (record.id !== stash) return [record];
      if (!members) return [];
      const left = record.members.filter((member) => !members.includes(member.id));
      return left.length ? [{ ...record, members: left }] : [];
    });
    this.changed();
  }

  private changed(): void {
    const seq = ++this.seq;
    for (const listener of this.subs) listener({ revision: seq }, seq);
  }
}

/** Sample stashes for the dev loop: an imported group, a workspace's pages, a whole workspace. */
export function sampleStashes(now: number): StashRecord[] {
  const HOUR = 3_600_000;
  return [
    {
      id: "s1",
      name: "atlas-web",
      created_at_ms: now - 0.5 * HOUR,
      members: [
        { id: "m1", kind: "tab", url: "https://docs.example.test/releases", title: "Atlas release notes" },
        {
          id: "m2",
          kind: "tab",
          url: "https://design.example.test/review/editor",
          title: "Design review — editor states",
        },
        { id: "m3", kind: "tab", url: "https://www.typescriptlang.org/docs/", title: "TypeScript handbook" },
      ],
    },
    {
      id: "s2",
      name: "backend",
      created_at_ms: now - 5 * HOUR,
      members: [
        {
          id: "w1",
          kind: "workspace",
          name: "backend",
          tab_count: 3,
          tabs: [
            { kind: "terminal", title: "cargo watch" },
            { kind: "browser", title: "API docs", url: "https://api.example.test/docs" },
            { kind: "terminal", title: "psql" },
          ],
        },
      ],
    },
    {
      id: "s3",
      created_at_ms: now - 30 * HOUR,
      members: [
        { id: "m1", kind: "tab", url: "https://news.example.test/", title: "Résumé of the week" },
        { id: "m2", kind: "tab", url: "https://example.org/long/path" },
      ],
    },
  ];
}
