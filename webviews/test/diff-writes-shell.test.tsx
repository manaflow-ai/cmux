// The diff viewer's write outbox belongs to one mount (src/diff-writes.ts). In the R94 page shell a
// claim does not reload the document: page.reset unmounts the viewer and the next claim mounts a
// new one in the same document. Nothing of page A (pending writes, refusals, trace) may reach page
// B: B starts idle with no errors, and A's unanswered write is not resent through B's host.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { installPageDiffComments } from "../src/comments/bridge";
import { useDiffWrites, type DiffWrites } from "../src/diff-writes";
import type { PageClient } from "../src/pages/shared/pageClient";
import { persistViewedChange, viewedScopeKey, type ViewedScope } from "../src/viewed-files";
import { installDom, privateCreateRoot, restoreDom } from "./viewer-empty-dom";

beforeAll(installDom);
afterAll(restoreDom);

/** A page host whose calls the test answers (or never answers). */
function host() {
  const calls: Array<{ method: string; opid?: string; answer(): void; refuse(): void }> = [];
  const page: PageClient = {
    call<R>(_op: string, params: unknown, options?: { opid?: string }): Promise<R> {
      const { method } = params as { method: string };
      return new Promise<R>((resolve, reject) =>
        calls.push({
          method,
          opid: options?.opid,
          answer: () => resolve({} as R),
          refuse: () => reject(Object.assign(new Error("refused"), { code: "cmux.diff.refused" })),
        }),
      );
    },
    subscribe: async () => () => undefined,
    handle: () => () => undefined,
  };
  return { page, calls };
}

/** The part of the viewer that owns the outbox. */
function Viewer({ onWrites }: { onWrites(writes: DiffWrites): void }) {
  onWrites(useDiffWrites());
  return null;
}

const scope: ViewedScope = { repoRoot: "/r", source: "branch:main" };
const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("page.reset with a pending write, then a new claim: the new page starts idle and nothing is resent", async () => {
  const createRoot = privateCreateRoot();
  // Claim A.
  const a = host();
  installPageDiffComments(a.page);
  let writesA: DiffWrites | null = null;
  const rootA = createRoot(document.body.appendChild(document.createElement("div")));
  await act(async () => rootA.render(<Viewer onWrites={(writes) => (writesA = writes)} />));
  persistViewedChange(scope, { kind: "set", entry: { path: "a.ts", fingerprint: "f" } }, writesA!);
  expect(a.calls.length).toBe(1);
  expect(writesA!.pending().length).toBe(1);

  // page.reset: the viewer unmounts; its outbox goes with it.
  await act(async () => rootA.unmount());
  expect(writesA!.pending()).toEqual([]);

  // Claim B, same document.
  const b = host();
  installPageDiffComments(b.page);
  let writesB: DiffWrites | null = null;
  const rootB = createRoot(document.body.appendChild(document.createElement("div")));
  await act(async () => rootB.render(<Viewer onWrites={(writes) => (writesB = writes)} />));
  expect(writesB).not.toBe(writesA);
  expect(writesB!.status(`viewed:${viewedScopeKey(scope)}:a.ts`)).toBe("idle");
  expect(writesB!.pending()).toEqual([]);
  expect(writesB!.errors).toEqual([]);
  expect(writesB!.trace()).toEqual([]);

  // A's host answers (or refuses) late: B sees nothing, and nothing goes to B's host.
  a.calls[0].refuse();
  await flush();
  expect(writesB!.errors).toEqual([]);
  expect(b.calls).toEqual([]);
  await act(async () => rootB.unmount());
  installPageDiffComments(null);
});
