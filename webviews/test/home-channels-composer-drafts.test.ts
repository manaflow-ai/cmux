// The docked Channels view is never let go while a composer holds unsent input:
// the page tells the host `draft` through `cmux.page.keepAlive` once the first composer holds text or
// files, and ends it once the last one sends or empties. No call per keystroke.
import { expect, test } from "bun:test";
import { KEEP_ALIVE_OP, type PageClient } from "../src/pages/shared/pageClient";
import { ComposerDrafts } from "../src/pages/home-channels/composerDrafts";

type KeepCall = { reason: string; on: boolean };

function recordingClient() {
  const keep: KeepCall[] = [];
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op !== KEEP_ALIVE_OP) throw new Error(`unexpected ${op}`);
      keep.push(params as KeepCall);
      return {} as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  return { client, keep };
}

test("the first composer with unsent input sets draft and the last one to empty ends it", () => {
  const { client, keep } = recordingClient();
  const drafts = new ComposerDrafts(client);
  const main = drafts.hold();
  const edit = drafts.hold();
  expect(drafts.held).toBe(true);
  expect(keep).toEqual([{ reason: "draft", on: true }]);
  main();
  expect(keep).toEqual([{ reason: "draft", on: true }]);
  edit();
  expect(drafts.held).toBe(false);
  expect(keep).toEqual([
    { reason: "draft", on: true },
    { reason: "draft", on: false },
  ]);
});

test("without a host the drafts are counted and nothing is sent", () => {
  const drafts = new ComposerDrafts(null);
  const release = drafts.hold();
  expect(drafts.held).toBe(true);
  release();
  expect(drafts.held).toBe(false);
});
