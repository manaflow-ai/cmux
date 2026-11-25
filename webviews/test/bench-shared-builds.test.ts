// cmux-web-test-timeout: 300
// bench/web-ui-suite.ts builds a page once (bench/support/prebuild.ts) and its benches take that build instead of
// building their own inside their timeouts (bench/support/sharedBuilds.ts). The first cut wrote the page's done marker
// in the page's own directory and looked for it in the pages directory, so no bench ever took the shared build: this
// runs the producer and then the consumer, end to end.
import { afterAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { serveBenchPage } from "../bench/support/benchPage";
import {
  SHARED_BUILD_DONE,
  SHARED_BUILD_ENV,
  markSharedBuildDone,
  sharedBuildDir,
  sharedPageKey,
  sharedPaneDir,
} from "../bench/support/sharedBuilds";

const webviews = path.resolve(import.meta.dir, "..");
const made: string[] = [];
const scratch = (name: string) => {
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), `bench-shared-${name}-`));
  made.push(dir);
  return dir;
};
afterAll(() => {
  for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
});

describe("the suite's shared builds", () => {
  test("a page prebuild.ts built is what serveBenchPage serves, with no build of its own, and close keeps it", async () => {
    const page = "/test/browser/long-task-queue.html";
    const pages = scratch("pages");
    const prebuild = Bun.spawnSync(["bun", "bench/support/prebuild.ts", "page", pages, page], {
      cwd: webviews,
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(prebuild.exitCode, prebuild.stderr.toString()).toBe(0);
    const dir = path.join(pages, sharedPageKey("vite.config.ts", page));
    expect(fs.existsSync(path.join(dir, SHARED_BUILD_DONE))).toBe(true);
    const before = fs.readdirSync(dir, { recursive: true }).length;

    const was = process.env[SHARED_BUILD_ENV.pages];
    process.env[SHARED_BUILD_ENV.pages] = pages;
    try {
      // `shared`: serveBenchPage served the prebuilt directory and ran no build of its own.
      const served = await serveBenchPage(page, { dev: false });
      expect(served.shared).toBe(true);
      const html = await (await fetch(served.url)).text();
      expect(html).toContain("<script");
      await served.close();
      expect(fs.readdirSync(dir, { recursive: true }).length).toBe(before);

      // An unminified run builds its own: the shared build is the default one.
      const own = await serveBenchPage(page, { dev: false, unminified: true });
      expect(own.shared).toBe(false);
      await own.close();
    } finally {
      if (was === undefined) delete process.env[SHARED_BUILD_ENV.pages];
      else process.env[SHARED_BUILD_ENV.pages] = was;
    }
  }, 240_000);

  test("a build is taken only once it is marked done, and a variant run never takes it", () => {
    const pane = scratch("pane");
    const env = { [SHARED_BUILD_ENV.pane]: pane };
    expect(sharedPaneDir({}, env)).toBeUndefined();
    markSharedBuildDone(pane);
    expect(sharedPaneDir({}, env)).toBe(pane);
    expect(sharedPaneDir({ variant: true }, env)).toBeUndefined();
    expect(sharedPaneDir({}, {})).toBeUndefined();
    expect(sharedBuildDir("gallery", env)).toBeUndefined();
  });
});
