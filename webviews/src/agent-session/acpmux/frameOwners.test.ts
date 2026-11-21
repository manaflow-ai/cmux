// `cmux app chat perf`'s frame owners (frameOwners.ts): which page code asks for frames, short
// timers and animations during a capture, by code location, with the page's functions put back after.
import { describe, expect, test } from "bun:test";
import {
  type OwnersEnv,
  type OwnersHost,
  type SiteTable,
  callerSite,
  describeTarget,
  resolveSite,
  runningAnimations,
  scriptPath,
  stackPosition,
  startFrameOwners,
} from "./frameOwners";

describe("frame owners: positions", () => {
  test("a stack line's position, in V8 and JavaScriptCore form", () => {
    expect(stackPosition("    at tick (cmux-page://cmux.agent/pane.js:1:4567)")).toEqual({
      url: "cmux-page://cmux.agent/pane.js",
      line: 1,
      column: 4567,
    });
    expect(stackPosition("    at cmux-page://cmux.agent/chunks/a-X1.js:3:9")?.column).toBe(9);
    expect(stackPosition("tick@cmux-page://cmux.agent/pane.js:1:20")?.url).toBe("cmux-page://cmux.agent/pane.js");
    expect(stackPosition("    at <anonymous>")).toBeNull();
  });

  test("a script URL is its path under the origin, without its query", () => {
    expect(scriptPath("cmux-page://cmux.agent/pane.js")).toBe("pane.js");
    expect(scriptPath("http://127.0.0.1:4176/src/agent-session/acpmux/flickerLog.ts?t=123")).toBe(
      "src/agent-session/acpmux/flickerLog.ts",
    );
    expect(scriptPath("cmux-page://cmux.agent/chunks/a-X1.js#x")).toBe("chunks/a-X1.js");
  });

  test("the caller is the frame past the wrapper", () => {
    const v8 =
      "Error\n    at requestAnimationFrame (cmux-page://a/pane.js:1:10)\n    at tick (cmux-page://a/pane.js:1:900)";
    expect(callerSite(v8)).toBe("pane.js:1:900");
    const jsc = "requestAnimationFrame@cmux-page://a/pane.js:1:10\ntick@cmux-page://a/pane.js:1:900";
    expect(callerSite(jsc)).toBe("pane.js:1:900");
    expect(callerSite(undefined)).toBe("(unknown)");
  });

  test("the site table names the source file behind a bundle position", () => {
    const table: SiteTable = {
      sources: ["node_modules/react-dom", "src/agent-session/acpmux/flickerLog.ts", "src/ui/spinnerClock.ts"],
      files: { "pane.js": [0, 0, 0, 0, 500, 1, 0, 900, 2, 2, 0, 1] },
    };
    expect(resolveSite(table, "pane.js:1:1")).toBe("node_modules/react-dom");
    expect(resolveSite(table, "pane.js:1:501")).toBe("src/agent-session/acpmux/flickerLog.ts");
    expect(resolveSite(table, "pane.js:1:900")).toBe("src/agent-session/acpmux/flickerLog.ts");
    expect(resolveSite(table, "pane.js:1:901")).toBe("src/ui/spinnerClock.ts");
    expect(resolveSite(table, "pane.js:3:1")).toBe("src/agent-session/acpmux/flickerLog.ts");
    expect(resolveSite(table, "chunks/other.js:1:1")).toBeNull();
    expect(resolveSite(null, "pane.js:1:1")).toBeNull();
  });
});

describe("frame owners: animations", () => {
  test("running animations group by name, target and iterations; finished ones and text are left out", () => {
    const target = {
      tagName: "SPAN",
      classList: ["cv-row-shimmer__band", "is-shimmer-active", "third"],
      textContent: "secret",
    };
    const timing = (iterations: number) => ({ target, getComputedTiming: () => ({ iterations }) });
    const report = runningAnimations([
      { playState: "running", animationName: "cmux-spin", effect: timing(Number.POSITIVE_INFINITY) },
      { playState: "running", animationName: "cmux-spin", effect: timing(Number.POSITIVE_INFINITY) },
      { playState: "running", transitionProperty: "opacity", effect: timing(1) },
      { playState: "finished", animationName: "acpmux-older-in", effect: timing(1) },
    ]);
    expect(report).toEqual([
      { name: "cmux-spin", target: "span.cv-row-shimmer__band.is-shimmer-active", iterations: "infinite", count: 2 },
      { name: "transition opacity", target: "span.cv-row-shimmer__band.is-shimmer-active", iterations: 1, count: 1 },
    ]);
    expect(JSON.stringify(report)).not.toContain("secret");
    expect(describeTarget(null)).toBe("?");
  });
});

function fakeOwnersEnv(table: SiteTable | null = null) {
  const calls = { frames: 0, timeouts: 0, intervals: 0, animate: 0 };
  const host: OwnersHost = {
    requestAnimationFrame: () => ++calls.frames,
    setTimeout: () => ++calls.timeouts,
    setInterval: () => ++calls.intervals,
  };
  const animateHost = { animate: () => ++calls.animate };
  let loads = 0;
  const env: OwnersEnv = {
    host,
    animateHost,
    animations: () => [],
    loadSites: async () => {
      loads += 1;
      return table;
    },
  };
  return { env, host, animateHost, calls, loads: () => loads };
}

describe("frame owners: the tally", () => {
  test("counts each caller of frames, short timers and animate, then puts the page's functions back", async () => {
    const page = fakeOwnersEnv();
    const original = { ...page.host, animate: page.animateHost.animate };
    const owners = startFrameOwners(page.env);
    expect(page.host.requestAnimationFrame).not.toBe(original.requestAnimationFrame);
    // A free-running loop: one request in each of three frames, two in the third.
    for (let frame = 0; frame < 3; frame += 1) {
      owners.frame();
      page.host.requestAnimationFrame(() => undefined);
    }
    page.host.requestAnimationFrame(() => undefined);
    page.host.setTimeout(() => undefined, 16);
    page.host.setTimeout(() => undefined, 1000);
    page.host.setInterval(() => undefined, 0);
    page.animateHost.animate();
    const report = await owners.report(2);
    expect(page.host.requestAnimationFrame).toBe(original.requestAnimationFrame);
    expect(page.host.setTimeout).toBe(original.setTimeout);
    expect(page.host.setInterval).toBe(original.setInterval);
    expect(page.animateHost.animate).toBe(original.animate);
    // Every call still reached the page's own function.
    expect(page.calls).toEqual({ frames: 4, timeouts: 2, intervals: 1, animate: 1 });
    expect(report.page_frames).toBe(3);
    expect(report.frames.reduce((sum, site) => sum + site.count, 0)).toBe(4);
    // Outside a bundle, the caller's own module path is its file: this test.
    expect(report.frames[0].file).toContain("frameOwners.test.ts");
    expect(report.frames[0].per_s).toBe(1.5);
    // The 1000 ms timeout is no frame-paced timer.
    expect(report.timers.map((site) => site.at.split(" ")[0]).sort()).toEqual(["interval", "timeout"]);
    expect(report.timers.every((site) => site.file?.includes("frameOwners.test.ts"))).toBe(true);
    expect(report.animate.length).toBe(1);
    // No bundle positions: the site table is never loaded.
    expect(page.loads()).toBe(0);
    expect(report.sites_resolved).toBe(false);
  });

  test("restore is idempotent, and a report after it finds nothing", async () => {
    const page = fakeOwnersEnv();
    const original = page.host.requestAnimationFrame;
    const owners = startFrameOwners(page.env);
    owners.restore();
    owners.restore();
    expect(page.host.requestAnimationFrame).toBe(original);
    const report = await owners.report(1);
    expect(report.frames).toEqual([]);
    expect(page.host.requestAnimationFrame).toBe(original);
  });
});
