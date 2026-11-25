// The custom properties the transcript writes on its scroller as the bottom stack moves are read on the
// scroller alone (its mask, its scroll padding), so they are registered as not inherited: a write then
// restyles the scroller and none of its rows. Inherited, every line the composer grew restyled every
// row in WebKit, 13-16 ms inside the key's frame (bench/composer-typing.bench.ts --mode L0 --engines
// webkit: the keys that wrap a line painted 23-44 ms after their frame, 10-23 ms with these).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url), "utf8");

const registered = (name: string): string | undefined => new RegExp(`@property ${name} \\{([^}]*)\\}`).exec(css)?.[1];

test.each([
  "--acpmux-dock-space",
  "--acpmux-dock-holes",
  "--acpmux-view-foot",
  "--acpmux-fade-top-reach",
  "--acpmux-fade-bottom-reach",
  "--acpmux-beside-images",
  "--acpmux-beside-sizes",
  "--acpmux-beside-positions",
])("%s is registered as not inherited", (name) => {
  expect(registered(name)).toContain("inherits: false");
});
