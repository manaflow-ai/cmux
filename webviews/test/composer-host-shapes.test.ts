// Leo, 2026-11-11: "attachments should be faster? if you're literally just pointing to a file path,
// why would it ever take time to load anything anyways?" The Mac host reads each image's size from its
// header as a drop, paste or pick goes to the page (AgentPaneGestureShapes.swift), so the chip has its
// final shape in its first frame. These pin how the page matches what it was told to the files.
import { afterEach, expect, test } from "bun:test";
import { hostShapes } from "../src/agent-session/acpmux/composer/attachmentIntakeModel";

const scope = globalThis as { __cmuxAttachShapes?: unknown };
const png = (name: string) => new File([new Uint8Array(8)], name, { type: "image/png" });
const zip = (name: string) => new File([new Uint8Array(8)], name, { type: "application/zip" });
const tell = (shapes: { name?: string | null; width: number; height: number }[], at = Date.now()) => {
  scope.__cmuxAttachShapes = { kind: "paste", at, shapes };
};

afterEach(() => {
  delete scope.__cmuxAttachShapes;
});

test("each image takes the size told for its name; other files take none", () => {
  tell([
    { name: "b.png", width: 900, height: 2880 },
    { name: "a.png", width: 2880, height: 1800 },
  ]);
  expect(hostShapes([png("a.png"), zip("c.zip"), png("b.png")])).toEqual([
    { width: 2880, height: 1800 },
    undefined,
    { width: 900, height: 2880 },
  ]);
});

test("a movie takes the size told for its name, never an unnamed one", () => {
  const mov = (name: string) => new File([new Uint8Array(8)], name, { type: "video/quicktime" });
  tell([
    { name: "Screen Recording.mov", width: 1920, height: 1080 },
    { width: 1512, height: 982 },
  ]);
  expect(hostShapes([mov("Screen Recording.mov")])).toEqual([{ width: 1920, height: 1080 }]);
  tell([{ width: 1512, height: 982 }]);
  expect(hostShapes([mov("clip.mov")])).toEqual([undefined]);
});

test("a pasted bitmap with no file name sizes the paste's only image", () => {
  tell([{ name: null, width: 1512, height: 982 }]);
  expect(hostShapes([png("image.png")])).toEqual([{ width: 1512, height: 982 }]);
});

test("an unnamed size never goes to one of several images", () => {
  tell([{ width: 1512, height: 982 }]);
  expect(hostShapes([png("one.png"), png("two.png")])).toEqual([undefined, undefined]);
});

test("what was told is used once: a later gesture never takes it", () => {
  tell([{ name: "a.png", width: 2880, height: 1800 }]);
  expect(hostShapes([png("a.png")])).toEqual([{ width: 2880, height: 1800 }]);
  expect(hostShapes([png("a.png")])).toEqual([undefined]);
});

test("a stale record, or none (an older host), sizes nothing", () => {
  tell([{ name: "a.png", width: 2880, height: 1800 }], Date.now() - 60_000);
  expect(hostShapes([png("a.png")])).toEqual([undefined]);
  expect(hostShapes([png("a.png")])).toEqual([undefined]);
});

test("a size that is not a positive number is none", () => {
  tell([{ name: "a.png", width: 0, height: 1800 }]);
  expect(hostShapes([png("a.png")])).toEqual([undefined]);
});
