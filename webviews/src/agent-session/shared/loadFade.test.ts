// The load window of shared/loadFade.ts on an injected clock: what arrives while a view loads, or
// within the window after, fades on a first mount soon after it arrived; a mount long after (a
// scroll reaching it) and a second mount never fade.
import { expect, test } from "bun:test";
import { LOAD_FADE_MOUNT_MS, LOAD_FADE_WINDOW_MS, LoadFadeWindow } from "./loadFade";

function clocked() {
  let now = 1000;
  const fade = new LoadFadeWindow(() => now);
  return { fade, at: (ms: number) => void (now = ms) };
}

test("the window is open while loading and for the window after, then closes", () => {
  const { fade, at } = clocked();
  fade.phase(false);
  expect(fade.open).toBe(false);
  fade.phase(true);
  expect(fade.open).toBe(true);
  at(5000);
  fade.phase(true);
  expect(fade.open).toBe(true);
  fade.phase(false);
  at(5000 + LOAD_FADE_WINDOW_MS);
  expect(fade.open).toBe(true);
  at(5001 + LOAD_FADE_WINDOW_MS);
  fade.phase(false);
  expect(fade.open).toBe(false);
});

test("an arrived item fades only on a first mount soon after it arrived", () => {
  const { fade, at } = clocked();
  fade.phase(true);
  fade.arrive("a");
  fade.arrive("b");
  expect(fade.fades("a")).toBe(true);
  // Pure until the mount consumes it.
  expect(fade.fades("a")).toBe(true);
  fade.shown("a");
  expect(fade.fades("a")).toBe(false);
  // "b" stayed off screen; a scroll mounts it later: drawn in place.
  at(1001 + LOAD_FADE_MOUNT_MS);
  expect(fade.fades("b")).toBe(false);
  expect(fade.fades("never-arrived")).toBe(false);
});

test("a closed window and a new view drop every waiting id", () => {
  const { fade, at } = clocked();
  fade.phase(true);
  fade.arrive("a");
  fade.phase(false);
  at(1001 + LOAD_FADE_WINDOW_MS);
  fade.phase(false);
  at(1000);
  expect(fade.fades("a")).toBe(false);
  fade.phase(true);
  fade.arrive("b");
  fade.clear();
  expect(fade.open).toBe(false);
  expect(fade.fades("b")).toBe(false);
});
