import { afterAll, expect, test } from "bun:test";
import { PNG } from "pngjs";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { countFrames } from "./frames";

const root = mkdtempSync(join(tmpdir(), "gallery-frames-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function png(path: string, flat: boolean) {
  const image = new PNG({ width: 8, height: 8 });
  for (let i = 0; i < 64; i++) image.data.set([20, 20, 20, 255], i * 4);
  if (!flat) image.data.set([240, 240, 240, 255], 9 * 4);
  writeFileSync(path, PNG.sync.write(image));
}

function run(name: string, frames: { ready: string | null; flat?: boolean; skip?: boolean }[]) {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  const results = frames.map((frame, i) => {
    const screenshot = `case-${i}.png`;
    if (!frame.skip) png(join(dir, screenshot), frame.flat ?? false);
    return { id: `case-${i}`, screenshot, ready: frame.ready };
  });
  writeFileSync(join(dir, "results.json"), JSON.stringify(results));
  return dir;
}

test("counts real, unready, missing and blank frames", () => {
  const dir = run("mixed", [{ ready: "1" }, { ready: null }, { ready: "1", skip: true }, { ready: "1", flat: true }]);
  expect(countFrames(dir)).toEqual({ total: 4, real: 1, unready: 1, missing: 1, blank: 1 });
});

test("a folder without results.json counts nothing", () => {
  expect(countFrames(join(root, "absent"))).toEqual({ total: 0, real: 0, unready: 0, missing: 0, blank: 0 });
});

test("--require fails a receipt with zero real frames and passes one with any", () => {
  const cli = (...dirs: string[]) =>
    spawnSync("bun", [join(import.meta.dir, "frames.ts"), ...dirs.flatMap((d) => ["--dir", d]), "--require"]).status;
  const blank = run("blank", [{ ready: "1", flat: true }, { ready: "error" }]);
  expect(cli(blank, join(root, "absent"))).toBe(1);
  expect(cli(join(root, "absent"))).toBe(1);
  expect(cli(blank, run("one-real", [{ ready: "1" }]))).toBe(0);
});
