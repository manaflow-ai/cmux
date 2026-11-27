import { afterEach, expect, test } from "bun:test";
import { clearPushedDrops, noteDomDrop, pushedDropPaths, receivePushedDrop } from "./dropPush";

afterEach(() => clearPushedDrops());

test("a fallback-winning drop discards its delayed native push", async () => {
  const file = new File(["contents"], "same-name.txt");
  noteDomDrop([file]);

  let answer!: (paths: readonly { path: string; folder: boolean }[]) => void;
  const result = pushedDropPaths([file], () => new Promise((resolve) => (answer = resolve)));
  answer([{ path: "/fallback/same-name.txt", folder: false }]);
  await expect(result).resolves.toEqual([{ path: "/fallback/same-name.txt", folder: false }]);

  // Chromium can deliver the native push after the older host's fallback reply. It belongs to the
  // completed drop and must not be reused by a later drop with the same basename.
  noteDomDrop([file]);
  receivePushedDrop({ local: true, items: [{ path: "/native/same-name.txt" }] });
  await expect(pushedDropPaths([file], async () => undefined)).resolves.toBeUndefined();
});
