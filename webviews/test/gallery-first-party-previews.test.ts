// The live gallery serves first-party-apps/<app>/preview, so an app's gallery entry reads its own
// scene fixtures instead of a copy under webviews; and nothing else of the app or the tree.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { firstPartyPreviewDirs } from "../dev-server/firstPartyPreviews";

setDefaultTimeout(120_000);
const made: string[] = [];
afterAll(() => {
  for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
});

function tree(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gallery-previews-"));
  made.push(root);
  const apps = path.join(root, "first-party-apps");
  fs.mkdirSync(path.join(apps, "widget-clock/preview"), { recursive: true });
  fs.writeFileSync(path.join(apps, "widget-clock/preview/scenes.json"), "{}");
  fs.mkdirSync(path.join(apps, "widget-clock/src"), { recursive: true });
  fs.mkdirSync(path.join(apps, "no-preview"), { recursive: true });
  fs.mkdirSync(path.join(apps, "file-preview"), { recursive: true });
  fs.writeFileSync(path.join(apps, "file-preview/preview"), "not a folder");
  // A preview that is a symlink out of the tree is not opened.
  fs.mkdirSync(path.join(root, "secrets"));
  fs.mkdirSync(path.join(apps, "linked"), { recursive: true });
  fs.symlinkSync(path.join(root, "secrets"), path.join(apps, "linked/preview"));
  return root;
}

test("only real preview folders inside first-party-apps are opened", () => {
  const root = tree();
  const apps = fs.realpathSync(path.join(root, "first-party-apps"));
  expect(firstPartyPreviewDirs(root)).toEqual([path.join(apps, "widget-clock/preview")]);
  expect(firstPartyPreviewDirs(path.join(root, "missing"))).toEqual([]);
});

test("the gallery dev server answers a preview fixture and refuses the app's other files and traversal", async () => {
  const root = tree();
  const preview = firstPartyPreviewDirs(root);
  fs.writeFileSync(path.join(root, "first-party-apps/widget-clock/src/main.ts"), "export {}");
  fs.writeFileSync(path.join(root, "secrets/token.json"), '{"token":"x"}');
  const { createServer } = await import("vite");
  const vite = await createServer({
    root: path.resolve(import.meta.dir, ".."),
    configFile: false,
    server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null, fs: { strict: true, allow: preview } },
    logLevel: "silent",
  });
  try {
    await vite.listen();
    const { port } = vite.httpServer!.address() as { port: number };
    const get = (file: string) => fetch(`http://127.0.0.1:${port}/@fs${file}`);
    const scenes = await get(path.join(preview[0]!, "scenes.json"));
    expect(scenes.status).toBe(200);
    const apps = fs.realpathSync(path.join(root, "first-party-apps"));
    expect((await get(path.join(apps, "widget-clock/src/main.ts"))).status).toBe(403);
    expect((await get(`${preview[0]}/../src/main.ts`)).status).not.toBe(200);
    expect((await get(`${preview[0]}/%2e%2e/src/main.ts`)).status).not.toBe(200);
    expect((await get(path.join(fs.realpathSync(root), "secrets/token.json"))).status).toBe(403);
  } finally {
    await vite.close();
  }
});
