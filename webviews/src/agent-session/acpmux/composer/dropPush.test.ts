import { afterEach, expect, test } from "bun:test";
import type { KnownPaths } from "../attachments";
import { clearPushedDrops, noteDomDrop, pushedDropPaths, receivePushedDrop } from "./dropPush";

afterEach(() => clearPushedDrops());

type Path = { path: string; folder: boolean };

function fallback(items: Path[], dropId: string): KnownPaths {
  const paths = items as KnownPaths;
  // Match intakeFiles.ts: the correlation id is metadata, not an enumerable path item.
  Object.defineProperty(paths, "dropId", { value: dropId });
  return paths;
}

test("a fallback-winning drop discards its delayed native push", async () => {
  const file = new File(["contents"], "same-name.txt");
  noteDomDrop([file]);

  let answer!: (paths: KnownPaths | undefined) => void;
  const result = pushedDropPaths([file], () => new Promise<KnownPaths | undefined>((resolve) => (answer = resolve)));
  answer(fallback([{ path: "/fallback/same-name.txt", folder: false }], "drop-a"));
  await expect(result).resolves.toEqual([{ path: "/fallback/same-name.txt", folder: false }]);

  // Chromium can deliver the native push after the older host's fallback reply. It belongs to the
  // completed drop and must not be reused by a later drop with the same basename.
  noteDomDrop([file]);
  receivePushedDrop({ id: "drop-a", local: true, items: [{ path: "/native/old/same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toBeUndefined();

  // A real subsequent drop with the same basename has a different host identity and is still
  // available after the stale record was consumed.
  noteDomDrop([file]);
  receivePushedDrop({ id: "drop-b", local: true, items: [{ path: "/native/new/same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toEqual([
    { path: "/native/new/same-name.txt", folder: false },
  ]);
});

test("a fallback that loses to the native push cannot tombstone a later drop", async () => {
  const file = new File(["contents"], "same-name.txt");
  noteDomDrop([file]);

  let answer!: (paths: KnownPaths | undefined) => void;
  const result = pushedDropPaths([file], () => new Promise<KnownPaths | undefined>((resolve) => (answer = resolve)));
  receivePushedDrop({ id: "drop-a", local: true, items: [{ path: "/native/first/same-name.txt" }] });
  await expect(result).resolves.toEqual([{ path: "/native/first/same-name.txt", folder: false }]);

  // The old host's answer can arrive after the native record already won. Its id must not
  // tombstone the next, distinct drop.
  answer(fallback([{ path: "/fallback/same-name.txt", folder: false }], "drop-a"));
  noteDomDrop([file]);
  receivePushedDrop({ id: "drop-b", local: true, items: [{ path: "/native/second/same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toEqual([
    { path: "/native/second/same-name.txt", folder: false },
  ]);
});
