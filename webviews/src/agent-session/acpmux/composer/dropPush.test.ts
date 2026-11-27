import { afterEach, expect, test } from "bun:test";
import { clearPushedDrops, noteDomDrop, pushedDropPaths, receivePushedDrop } from "./dropPush";

afterEach(() => clearPushedDrops());

test("a fallback-winning drop discards its delayed native push", async () => {
  const file = new File(["contents"], "same-name.txt");
  noteDomDrop([file]);

  let answer!: (paths: readonly { path: string; folder: boolean }[]) => void;
  const result = pushedDropPaths([file], () => new Promise((resolve) => (answer = resolve)));
  const fallback = [{ path: "/fallback/same-name.txt", folder: false }] as readonly {
    path: string;
    folder: boolean;
  }[] & {
    dropId?: string;
  };
  fallback.dropId = "drop-a";
  answer(fallback);
  await expect(result).resolves.toEqual([{ path: "/fallback/same-name.txt", folder: false }]);

  // Chromium can deliver the native push after the older host's fallback reply. It belongs to the
  // completed drop and must not be reused by a later drop with the same basename.
  noteDomDrop([file]);
  receivePushedDrop({ id: "drop-a", local: true, items: [{ path: "/native/same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toBeUndefined();

  // A real subsequent drop with the same basename has a different host identity and is still
  // available after the stale record was consumed.
  receivePushedDrop({ id: "drop-b", local: true, items: [{ path: "/native/new-same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toEqual([
    { path: "/native/new-same-name.txt", folder: false },
  ]);
});

test("a fallback that loses to the native push cannot tombstone a later drop", async () => {
  const file = new File(["contents"], "same-name.txt");
  noteDomDrop([file]);

  let answer!: (paths: readonly { path: string; folder: boolean }[]) => void;
  const result = pushedDropPaths([file], () => new Promise((resolve) => (answer = resolve)));
  receivePushedDrop({ id: "drop-a", local: true, items: [{ path: "/native/first.txt" }] });
  await expect(result).resolves.toEqual([{ path: "/native/first.txt", folder: false }]);

  const fallback = [{ path: "/fallback/same-name.txt", folder: false }] as readonly {
    path: string;
    folder: boolean;
  }[] & {
    dropId?: string;
  };
  fallback.dropId = "drop-a";
  answer(fallback);
  noteDomDrop([file]);
  receivePushedDrop({ id: "drop-b", local: true, items: [{ path: "/native/second.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toEqual([
    { path: "/native/second.txt", folder: false },
  ]);
});
