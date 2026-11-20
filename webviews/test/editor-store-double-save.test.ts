// Cmd-S pressed twice while format on save is still running: the second save must not write beside
// the first. Both would send the same base hash, which the first write has moved, so the host would
// refuse the second as a conflict with the person's own text.
import { expect, test } from "bun:test";
import { EDITOR_CONFIG_OP, EDITOR_SAVE_OP } from "../src/pages/editor/host";
import { EditorStore, type CodeView } from "../src/pages/editor/store";
import type { PageClient } from "../src/pages/shared/pageClient";

const tick = () => new Promise<void>((done) => setTimeout(done, 0));

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => (resolve = done));
  return { promise, resolve };
}

test("a second save that finished formatting while the first writes does not write again", async () => {
  const saves: unknown[] = [];
  const write = deferred();
  const client = {
    call: async (op: string, params: unknown) => {
      if (op === EDITOR_CONFIG_OP) {
        return { path: "/w/a.ts", text: "a  \n", hash: "h1", settings: { trimTrailingWhitespace: true } };
      }
      if (op === EDITOR_SAVE_OP) {
        saves.push(params);
        await write.promise;
        return { hash: "h2" };
      }
      return null;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  } as unknown as PageClient;
  const store = new EditorStore(client);
  let text = "a  \n";
  let version = 1;
  const prepares = [deferred(), deferred()];
  let prepared = 0;
  const view: CodeView = {
    load: () => {},
    text: () => text,
    version: () => version,
    setReadOnly: () => {},
    prepareSave: async () => {
      const mine = prepares[prepared++];
      await mine.promise;
      if (text !== "a\n") {
        text = "a\n";
        version += 1;
      }
    },
  };
  store.attachView(view);
  await store.start();
  // The person edits, then presses Cmd-S twice.
  version += 1;
  store.edited();
  const first = store.save({ format: true });
  const second = store.save({ format: true });
  prepares[0].resolve();
  await tick();
  expect(saves).toHaveLength(1);
  prepares[1].resolve();
  await tick();
  write.resolve();
  await Promise.all([first, second]);

  expect(saves).toHaveLength(1);
  expect(store.getState().conflict).toBeNull();
  expect(store.getState().status).toBe("saved");
});
