// The diff viewer's host writes go through the intent outbox (src/diff-writes.ts): per file in
// order, a newer mark replacing a queued one, an opid on each write (decision 31).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { installPageDiffComments } from "../src/comments/bridge";
import { createDiffWrites, DIFF_WRITE_KINDS, type DiffWrites } from "../src/diff-writes";
import type { PageCallOptions, PageClient } from "../src/pages/shared/pageClient";
import { persistViewedChange, type ViewedChange, type ViewedFileEntry, type ViewedScope } from "../src/viewed-files";
import { saveViewerPrefs } from "../src/viewer-prefs";

interface Posted {
  method: string;
  params: Record<string, unknown>;
  opid?: string;
  answer(): void;
}

function fakePage() {
  const posted: Posted[] = [];
  const page: PageClient = {
    call<R>(_op: string, params: unknown, options?: PageCallOptions): Promise<R> {
      const { method, params: inner } = params as { method: string; params: Record<string, unknown> };
      return new Promise<R>((resolve) =>
        posted.push({ method, params: inner, opid: options?.opid, answer: () => resolve({} as R) }),
      );
    },
    subscribe: async () => () => undefined,
    handle: () => () => undefined,
  };
  return { page, posted };
}

const flush = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

const scope: ViewedScope = { repoRoot: "/r", source: "branch:main" };
const set = (path: string): ViewedChange => ({ kind: "set", entry: { path, fingerprint: "f" } as ViewedFileEntry });
const clear = (path: string): ViewedChange => ({ kind: "clear", path });

let writes: DiffWrites;
beforeEach(() => {
  writes = createDiffWrites();
});
afterEach(() => {
  installPageDiffComments(null);
  writes.dispose();
});

describe("diff writes", () => {
  test("Swift-routed: every kind confirms on ok, and the outbox builds without opid echo", () => {
    // The PageRouter does not echo opids on events, so an event-confirmed kind would never settle.
    for (const [name, kind] of Object.entries(DIFF_WRITE_KINDS)) {
      expect({ name, confirm: kind.confirm ?? "ok" }).toEqual({ name, confirm: "ok" });
    }
    expect(() => createDiffWrites().dispose()).not.toThrow();
  });

  test("quick toggles of one file: one write in flight, the newest queued one wins", async () => {
    const { page, posted } = fakePage();
    installPageDiffComments(page);
    persistViewedChange(scope, set("a.ts"), writes);
    persistViewedChange(scope, clear("a.ts"), writes);
    persistViewedChange(scope, set("a.ts"), writes);
    expect(posted.map((p) => p.method)).toEqual(["viewedFiles.set"]);
    posted[0].answer();
    await flush();
    // The queued clear was replaced by the newer set: the host ends at the user's last state.
    expect(posted.map((p) => p.method)).toEqual(["viewedFiles.set", "viewedFiles.set"]);
    expect(posted.every((p) => typeof p.opid === "string" && p.opid.length > 0)).toBe(true);
    expect(new Set(posted.map((p) => p.opid)).size).toBe(2);
  });

  test("different files and preference keys do not wait for each other", () => {
    const { page, posted } = fakePage();
    installPageDiffComments(page);
    persistViewedChange(scope, set("a.ts"), writes);
    persistViewedChange(scope, set("b.ts"), writes);
    saveViewerPrefs({ layout: "unified" }, writes);
    saveViewerPrefs({ wordWrap: true }, writes);
    expect(posted.map((p) => p.method)).toEqual([
      "viewedFiles.set",
      "viewedFiles.set",
      "viewerPrefs.set",
      "viewerPrefs.set",
    ]);
  });
});
