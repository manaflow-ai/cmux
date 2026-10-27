import { readFileSync } from "node:fs";
import { expect, test } from "bun:test";
import { avatarSet } from "./sets";
import { AVATAR_STATES, avatarTrack, parseAvatarManifest, sheetSize, type AvatarManifest } from "./format";

const SETS = ["mochi", "captain", "sprout", "bolt"];
const manifest = (value: unknown): AvatarManifest => {
  const parsed = parseAvatarManifest(value);
  if ("error" in parsed) throw new Error(parsed.error);
  return parsed.manifest;
};
const minimal = {
  format: "cmux-avatar/1",
  id: "pip",
  name: "Pip",
  sheet: "sheet.png",
  frame: { width: 32, height: 32 },
};

/** A PNG's width and height, from its IHDR. */
const pngSize = (bytes: Buffer) => ({ width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) });

test("every built-in set has all six states, fits its sheet and stays a few KB", () => {
  for (const id of SETS) {
    const dir = new URL(`./sets/${id}/`, import.meta.url);
    const parsed = manifest(JSON.parse(readFileSync(new URL("avatar.json", dir), "utf8")));
    expect(parsed.id).toBe(id);
    expect(Object.keys(parsed.states).sort()).toEqual([...AVATAR_STATES].sort());
    const sheet = readFileSync(new URL(parsed.sheet, dir));
    const need = sheetSize(parsed);
    const size = pngSize(sheet);
    expect(size.width).toBeGreaterThanOrEqual(need.width);
    expect(size.height).toBeGreaterThanOrEqual(need.height);
    // The size sets.ts declares is the PNG's own: the renderer cuts cells by it.
    expect(avatarSet(id)?.size).toEqual(size);
    expect(sheet.length).toBeLessThan(4096);
    // done and error play once and hold their last frame; the rest loop.
    expect(parsed.states.done?.loop).toBe(false);
    expect(parsed.states.error?.loop).toBe(false);
    expect(avatarTrack(parsed, "working", "right").frames).toBeGreaterThan(1);
  }
});

test("a manifest with only idle is valid, and every other state falls back to a drawn row", () => {
  const parsed = manifest({ ...minimal, states: { idle: { row: 0, frames: 2 } } });
  expect(parsed.fps).toBe(8);
  expect(parsed.faces).toBe("right");
  for (const state of AVATAR_STATES) expect(avatarTrack(parsed, state, "right").row).toBe(0);
});

test("thinking falls back to working, which falls back to idle", () => {
  const parsed = manifest({
    ...minimal,
    states: { idle: { row: 0, frames: 2 }, working: { row: 3, frames: 6, fps: 12 } },
  });
  expect(avatarTrack(parsed, "thinking", "right")).toEqual({ row: 3, frames: 6, fps: 12, loop: true, mirrored: false });
  expect(avatarTrack(parsed, "waiting", "right").row).toBe(0);
});

test("the other facing mirrors the row unless the manifest draws it", () => {
  const parsed = manifest({
    ...minimal,
    states: { idle: { row: 0, frames: 4 }, working: { row: 1, frames: 6, rowLeft: 6 } },
  });
  expect(avatarTrack(parsed, "idle", "left")).toMatchObject({ row: 0, mirrored: true });
  expect(avatarTrack(parsed, "idle", "right")).toMatchObject({ row: 0, mirrored: false });
  expect(avatarTrack(parsed, "working", "left")).toMatchObject({ row: 6, mirrored: false });
  // A row for the facing the frames are already drawn in is not used: that facing is `row`.
  const both = manifest({ ...minimal, states: { idle: { row: 0, frames: 4, rowRight: 5, rowLeft: 6 } } });
  expect(avatarTrack(both, "idle", "right")).toMatchObject({ row: 0, mirrored: false });
  expect(avatarTrack(both, "idle", "left")).toMatchObject({ row: 6, mirrored: false });
  const left = manifest({ ...minimal, faces: "left", states: { idle: { row: 0, frames: 4 } } });
  expect(avatarTrack(left, "idle", "right").mirrored).toBe(true);
  expect(sheetSize(parsed)).toEqual({ width: 6 * 32, height: 7 * 32 });
});

test("an upload outside the format is refused with its reason", () => {
  const refused = (value: unknown) => {
    const parsed = parseAvatarManifest(value);
    return "error" in parsed ? parsed.error : null;
  };
  expect(refused({ ...minimal, format: "cmux-avatar/2", states: { idle: { row: 0, frames: 1 } } })).toContain("format");
  expect(refused({ ...minimal, states: { working: { row: 0, frames: 1 } } })).toBe("states.idle is required");
  expect(refused({ ...minimal, states: { idle: { row: 0, frames: 17 } } })).toContain("frames");
  expect(refused({ ...minimal, sheet: "../x.png", states: { idle: { row: 0, frames: 1 } } })).toContain("sheet");
  expect(refused({ ...minimal, frame: { width: 4, height: 32 }, states: { idle: { row: 0, frames: 1 } } })).toContain(
    "frame",
  );
  expect(refused({ ...minimal, states: { idle: { row: 0, frames: 1, loop: "no" } } })).toContain("loop");
  expect(refused({ ...minimal, pixelArt: "yes", states: { idle: { row: 0, frames: 1 } } })).toContain("pixelArt");
  const big = { ...minimal, frame: { width: 256, height: 256 } };
  expect(refused({ ...big, states: { idle: { row: 0, frames: 16 } } })).toContain("2048");
  expect(refused({ ...big, states: { idle: { row: 15, frames: 1 } } })).toContain("2048");
  expect(refused({ ...big, states: { idle: { row: 7, frames: 8 } } })).toBeNull();
  // Unknown fields and states are ignored, not refused.
  expect(
    refused({ ...minimal, extra: 1, states: { idle: { row: 0, frames: 1 }, dancing: { row: 9, frames: 3 } } }),
  ).toBeNull();
});
