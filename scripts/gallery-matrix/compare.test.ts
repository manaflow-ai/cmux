import { afterAll, expect, test } from "bun:test";
import { PNG } from "pngjs";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeAfterThumb, changedBoxes, compareRuns, diffMask, settleLatency, type Outcome } from "./compare";
import { COMMENT_MARKER, commentMarkdown, diffPage, feedSummary, filteredCounts, liveBase, summaryLine } from "./report";

const root = mkdtempSync(join(tmpdir(), "gallery-pr-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

/** A gray image with optional colored rectangles. */
function image(
  width: number,
  height: number,
  rects: { x: number; y: number; w: number; h: number; rgb: number[] }[] = [],
) {
  const png = new PNG({ width, height });
  for (let i = 0; i < width * height; i++) png.data.set([128, 128, 128, 255], i * 4);
  for (const r of rects)
    for (let y = r.y; y < r.y + r.h; y++)
      for (let x = r.x; x < r.x + r.w; x++) png.data.set([...r.rgb, 255], (y * width + x) * 4);
  return png;
}

test("two far-apart changes are two boxes; near ones merge", () => {
  const a = image(200, 100);
  const b = image(200, 100, [
    { x: 10, y: 10, w: 6, h: 6, rgb: [255, 0, 0] },
    { x: 20, y: 12, w: 4, h: 4, rgb: [0, 0, 255] },
    { x: 150, y: 70, w: 10, h: 10, rgb: [0, 255, 0] },
  ]);
  const diff = diffMask(a, b);
  expect(diff.pixels).toBe(36 + 16 + 100);
  const boxes = changedBoxes(diff.mask, diff.width, diff.height);
  expect(boxes).toHaveLength(2);
  expect(boxes[0]).toEqual({ x: 8, y: 8, w: 16, h: 8 });
  expect(boxes[1]).toEqual({ x: 144, y: 64, w: 16, h: 16 });
});

test("identical images have no changed pixels; a size change counts the new area", () => {
  expect(diffMask(image(40, 40), image(40, 40)).pixels).toBe(0);
  const grown = diffMask(image(40, 40), image(40, 50));
  expect([grown.width, grown.height]).toEqual([40, 50]);
  expect(grown.pixels).toBe(400);
});

test("the thumbnail puts before and after side by side around the change", () => {
  const thumb = beforeAfterThumb(
    image(400, 300),
    image(400, 300, [{ x: 100, y: 100, w: 20, h: 20, rgb: [255, 0, 0] }]),
    [{ x: 96, y: 96, w: 24, h: 24 }],
  );
  // 24 + 2 * 24 padding on each side = 72 wide per side, plus the 8 px gap.
  expect([thumb.width, thumb.height]).toEqual([72 * 2 + 8, 72]);
});

type PlayStepFixture = { png: PNG; layoutShift?: number; longFrames?: number[]; settleMs?: number; problems?: string[] };
function run(
  name: string,
  shots: {
    id: string;
    png?: PNG;
    ready?: string;
    params?: Record<string, unknown>;
    steps?: PlayStepFixture[];
    playError?: string;
  }[],
) {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  const results = shots.map((s) => {
    const screenshot = `${s.id}-chromium.png`;
    if (s.png) writeFileSync(join(dir, screenshot), PNG.sync.write(s.png));
    const steps = (s.steps ?? []).map((step, index) => {
      const still = `${s.id}-chromium--step-${String(index + 1).padStart(2, "0")}.png`;
      writeFileSync(join(dir, still), PNG.sync.write(step.png));
      return { index, step: `click step ${index + 1}`, screenshot: still };
    });
    const play = s.steps && {
      status: s.playError || s.steps.some((step) => step.problems?.length) ? "fail" : "pass",
      error: s.playError,
      steps: s.steps.map((step, index) => ({
        step: `click step ${index + 1}`,
        status: step.problems?.length ? "fail" : "pass",
        layoutShift: step.layoutShift ?? 0,
        longFrames: step.longFrames ?? [],
        frameSource: "long-animation-frame",
        ...(step.settleMs === undefined ? {} : { settleMs: step.settleMs }),
        problems: step.problems ?? [],
      })),
    };
    return {
      id: s.id,
      engine: "chromium",
      screenshot,
      ready: s.ready ?? "1",
      params: s.params ?? { entry: s.id.split("--")[0], variant: s.id.split("--")[1], theme: "Dark" },
      ...(play ? { play, steps } : {}),
    };
  });
  writeFileSync(join(dir, "results.json"), JSON.stringify(results));
  return dir;
}

test("runs sort into changed, new, removed, broken, nondeterministic and unchanged", () => {
  const same = image(60, 40);
  const moved = image(60, 40, [{ x: 4, y: 4, w: 8, h: 8, rgb: [0, 0, 255] }]);
  const base = run("base", [
    { id: "pane.composer--idle", png: same },
    { id: "pane.composer--draft", png: same },
    { id: "pane.old--gone", png: same },
    { id: "pane.clock--now", png: same },
    { id: "pane.crash--x", png: same },
  ]);
  const head = run("head", [
    { id: "pane.composer--idle", png: moved },
    { id: "pane.composer--draft", png: same },
    { id: "pane.added--fresh", png: same },
    { id: "pane.clock--now", png: same },
    { id: "pane.crash--x", ready: "error" },
  ]);
  const repeat = run("repeat", [
    { id: "pane.composer--idle", png: moved },
    { id: "pane.composer--draft", png: same },
    { id: "pane.added--fresh", png: same },
    { id: "pane.clock--now", png: moved },
    { id: "pane.crash--x", ready: "error" },
  ]);
  const out = join(root, "diff");
  const ids = (...list: string[]) => new Set(list);
  const outcomes = compareRuns({
    baseDir: base,
    headDir: head,
    repeatDir: repeat,
    baseIds: ids("pane.composer--idle", "pane.composer--draft", "pane.old--gone", "pane.clock--now", "pane.crash--x"),
    headIds: ids(
      "pane.composer--idle",
      "pane.composer--draft",
      "pane.added--fresh",
      "pane.clock--now",
      "pane.crash--x",
    ),
    outDir: out,
  });
  expect(outcomes.map((o) => [o.id, o.status])).toEqual([
    ["pane.composer--idle", "changed"],
    ["pane.added--fresh", "new"],
    ["pane.old--gone", "removed"],
    ["pane.crash--x", "broken"],
    ["pane.clock--now", "nondeterministic"],
    ["pane.composer--draft", "unchanged"],
  ]);
  const changed = outcomes[0]!;
  expect(changed.boxes).toEqual([{ x: 0, y: 0, w: 16, h: 16 }]);
  for (const file of [changed.base!, changed.head!, changed.thumb!]) expect(existsSync(join(out, file))).toBe(true);
  // A nondeterministic state is reported, never as a PR change, and has no before image.
  expect(outcomes[4]!.base).toBeUndefined();
});

function outcome(o: Partial<Outcome>): Outcome {
  const full: Outcome = {
    key: "",
    id: "",
    entry: "agent-pane.composer",
    variant: "idle",
    theme: "Dark",
    engine: "chromium",
    status: "changed",
    width: 100,
    height: 100,
    pixels: 10,
    ratio: 0.001,
    boxes: [{ x: 0, y: 0, w: 8, h: 8 }],
    thumb: "thumbs/x.png",
    ...o,
  };
  full.id ||= `${full.entry}--${full.variant}`;
  full.key ||= `${full.id}-${full.engine}.png`;
  return full;
}
const meta = {
  pr: 18189,
  head: "e574a65ba50ef129",
  base: "1960804a7c4ea264",
  links: { diff: "https://g/pr-18189/diff/", thumbBase: "https://raw/pr-media/18189/gallery-e574a65-" },
};

test("the summary names changed states once each and the other counts", () => {
  const list = [
    outcome({ variant: "idle", theme: "Dark" }),
    outcome({ variant: "idle", theme: "Light" }),
    outcome({ variant: "streaming" }),
    outcome({ entry: "pages.diff", variant: "split", status: "new" }),
    outcome({ variant: "draft", status: "unchanged" }),
  ];
  expect(summaryLine(list)).toBe(
    "3 states changed: agent-pane.composer/idle, agent-pane.composer/streaming · 1 new state",
  );
  expect(summaryLine([outcome({ status: "unchanged" })])).toBe("No state changed");
  const feed = feedSummary(list, meta);
  expect(feed.counts.changed).toBe(3);
  expect(feed.changed[0]).toMatchObject({ state: "agent-pane.composer/idle (Dark)", thumb: "https://raw/pr-media/18189/gallery-e574a65-agent-pane.composer-idle-chromium.png" });
});

test("the comment is marked, links the diff page and shows thumbnails; nondeterminism is set apart", () => {
  const md = commentMarkdown([outcome({}), outcome({ variant: "clock", status: "nondeterministic" })], meta);
  expect(md.startsWith(COMMENT_MARKER)).toBe(true);
  expect(md).toContain("**1 state changed: agent-pane.composer/idle**");
  expect(md).toContain("[Diff page](https://g/pr-18189/diff/)");
  expect(md).toContain('<img src="https://raw/pr-media/18189/gallery-e574a65-agent-pane.composer-idle-chromium.png" width="480">');
  expect(md).toContain("1 nondeterministic state differed from a second render");
});

test("the comment links each changed or new state's page in the branch's live preview, path only", () => {
  expect(liveBase("next/Composer-Queue_actions")).toBe("/wt/next-composer-queue-actions/");
  expect(liveBase("a".repeat(39) + "/b")).toBe(`/wt/${"a".repeat(39)}/`);
  expect(liveBase("///")).toBeUndefined();
  const live = { ...meta, links: { ...meta.links, live: liveBase("next/composer-queue-actions") } };
  const md = commentMarkdown(
    [
      outcome({ theme: "Dark" }),
      outcome({ theme: "Light" }),
      outcome({ entry: "pages.diff", variant: "split", status: "new" }),
      outcome({ variant: "same", status: "unchanged" }),
      outcome({ variant: "x#/../y" }),
    ],
    live,
  );
  expect(md).toContain(
    "- agent-pane.composer/idle: `/wt/next-composer-queue-actions/?entry=agent-pane.composer#/agent-pane.composer/idle`",
  );
  expect(md).toContain("- pages.diff/split: `/wt/next-composer-queue-actions/?entry=pages.diff#/pages.diff/split`");
  // One line per page (themes share it), none for unchanged states or unsafe names, and no host.
  expect(md.match(/agent-pane\.composer\/idle: /g)).toHaveLength(1);
  expect(md).not.toContain("/same`");
  expect(md).not.toContain("#/agent-pane.composer/x#");
  expect(md).not.toContain("https://cmux");
  expect(commentMarkdown([outcome({})], meta)).not.toContain("Live preview");
  expect(diffPage([outcome({})], live)).toContain("Live previews (1)");
  expect(diffPage([outcome({})], live)).toContain("/wt/next-composer-queue-actions/?entry=agent-pane.composer");
});

// Prints the name scripts/pr-media.py stores a file under (its sanitize()).
const STORED_NAME = [
  "import importlib.util, sys",
  "spec = importlib.util.spec_from_file_location('pr_media', sys.argv[1])",
  "module = sys.modules[spec.name] = importlib.util.module_from_spec(spec)",
  "spec.loader.exec_module(module)",
  "print(module.sanitize(sys.argv[2]))",
].join("\n");

// gallery-pr.yml uploads each thumbnail as <prefix><key> through scripts/pr-media.py, which stores it
// under that tool's sanitized name, so a link must name the file the uploader actually wrote.
test("thumbnail links name the file pr-media.py stores", () => {
  const o = outcome({});
  const local = `gallery-e574a65-${o.key}`;
  const tool = join(import.meta.dir, "..", "pr-media.py");
  const run = spawnSync("python3", ["-I", "-c", STORED_NAME, tool, local], { encoding: "utf8" });
  expect(run.status).toBe(0);
  const stored = run.stdout.trim();
  expect(commentMarkdown([o], meta)).toContain(`<img src="https://raw/pr-media/18189/${stored}" width="480">`);
  expect(feedSummary([o], meta).changed[0]?.thumb).toBe(`https://raw/pr-media/18189/${stored}`);
});

test("the diff page embeds its data safely and lists changed states first", () => {
  const html = diffPage(
    [outcome({ variant: "</script><b>" }), outcome({ variant: "same", status: "unchanged" })],
    meta,
  );
  expect(html).not.toContain("</script><b>");
  expect(html).toContain("PR #18189 gallery diff");
  expect(html).toContain('id="entry-filter"');
  expect(html).toContain('{id: o.key, "data-entry": o.entry}');
  expect(html).toContain("applyEntryFilter");
  expect(html).toContain('ul.plain [data-entry]');
  expect(html).toContain('article[data-entry]');
  expect(html).toContain('filteredCounts[status]');
  expect(html.indexOf('"status":"changed"')).toBeLessThan(html.indexOf('"status":"unchanged"'));
  expect(readFileSync(new URL("./report.ts", import.meta.url), "utf8")).toContain("onion");
});

test("entry-filter counts only outcomes belonging to the selected entry", () => {
  const outcomes = [
    outcome({ entry: "agent-pane.composer", status: "unchanged" }),
    outcome({ entry: "agent-pane.composer", status: "broken" }),
    outcome({ entry: "pages.markdown", status: "changed" }),
  ];
  expect(filteredCounts(outcomes, "agent-pane.composer")).toEqual({
    changed: 0,
    new: 0,
    removed: 0,
    broken: 1,
    nondeterministic: 0,
    unchanged: 1,
  });
});

test("play-failed unchanged states stay out of the unchanged list", () => {
  const html = diffPage(
    [
      outcome({ entry: "agent-pane.composer", status: "unchanged", play: { status: "fail" } }),
      outcome({ entry: "pages.markdown", status: "unchanged" }),
    ],
    meta,
  );
  // The page gives failed states their own cards. They must not also be counted in the folded list.
  expect(html).toContain('const unchanged = list.filter(([o]) => !o.play || o.play.status !== "fail");');
  expect(html).toContain('unchanged.length + " unchanged"');
});

test("a played state gets a filmstrip; a step that moved changes the state even when the final still holds", () => {
  const closed = image(60, 40);
  const open = image(60, 40, [{ x: 30, y: 4, w: 20, h: 20, rgb: [0, 0, 255] }]);
  const shifted = image(60, 40, [{ x: 30, y: 8, w: 20, h: 20, rgb: [0, 0, 255] }]);
  const id = "pane.menu--slash";
  const base = run("play-base", [{ id, png: closed, steps: [{ png: open }, { png: closed }] }]);
  const head = run("play-head", [
    {
      id,
      png: closed,
      steps: [{ png: shifted, layoutShift: 0.12, problems: ["layout shift 0.120"] }, { png: closed }],
    },
  ]);
  const repeat = run("play-repeat", [{ id, png: closed, steps: [{ png: shifted }, { png: closed }] }]);
  const [outcome] = compareRuns({
    baseDir: base,
    headDir: head,
    repeatDir: repeat,
    baseIds: new Set([id]),
    headIds: new Set([id]),
    outDir: join(root, "play-diff"),
  });
  expect(outcome!.status).toBe("changed");
  expect(outcome!.pixels).toBe(0);
  expect(outcome!.frames!.map((f) => [f.index, f.status])).toEqual([
    [0, "changed"],
    [1, "unchanged"],
  ]);
  expect(outcome!.frames![0]!.play).toMatchObject({
    status: "fail",
    layoutShift: 0.12,
    problems: ["layout shift 0.120"],
  });
  expect(outcome!.frames![0]!.basePlay).toMatchObject({ status: "pass", layoutShift: 0 });
  expect(outcome!.frames![1]!.base).toBeTruthy();
  expect(outcome!.frames![1]!.head).toBeTruthy();
  expect(existsSync(join(root, "play-diff", outcome!.frames![1]!.base!))).toBe(true);
  expect(existsSync(join(root, "play-diff", outcome!.frames![1]!.head!))).toBe(true);
  expect(outcome!.play).toEqual({ status: "fail", error: undefined });
  // The thumbnail comes from the step that changed.
  expect(existsSync(join(root, "play-diff", outcome!.thumb!))).toBe(true);
  expect(summaryLine([outcome!])).toBe("1 state changed: pane.menu/slash · 1 play check failed");
  const md = commentMarkdown([outcome!], meta);
  expect(md).toContain("**Play checks failed**");
  expect(md).toContain("pane.menu/slash: step 1 click step 1: layout shift 0.120");
  const html = diffPage([outcome!], meta);
  expect(html).toContain("frame-cell");
  expect(html).toContain("play: undefined");
});

test("settle latency summarizes available head steps and appears on the ordinary card", () => {
  const frames = [10, 20, 40].map((settleMs, index) => ({
    index,
    step: `click step ${index + 1}`,
    status: "unchanged" as const,
    width: 40,
    height: 30,
    pixels: 0,
    ratio: 0,
    boxes: [],
    play: { status: "pass", layoutShift: 0, longFrames: 0, longFrameMaxMs: 0, problems: [], settleMs },
  }));
  expect(settleLatency(frames)).toEqual({ count: 3, p50: 20, p95: 40, max: 40 });
  const html = diffPage([outcome({ frames })], meta);
  expect(html).toContain("action → settled: p50 ");
  expect(html).toContain("summary.p50.toFixed(1)");
  expect(html).toContain("summary.count");
  const legacy = frames.map(({ play, ...frame }) => frame);
  expect(settleLatency(legacy)).toBeUndefined();
});

test("a step that differs from itself makes an otherwise unchanged state nondeterministic", () => {
  const still = image(40, 30);
  const blink = image(40, 30, [{ x: 2, y: 2, w: 4, h: 4, rgb: [255, 255, 255] }]);
  const id = "pane.caret--blink";
  const base = run("blink-base", [{ id, png: still, steps: [{ png: still }] }]);
  const head = run("blink-head", [{ id, png: still, steps: [{ png: still }] }]);
  const repeat = run("blink-repeat", [{ id, png: still, steps: [{ png: blink }] }]);
  const [outcome] = compareRuns({
    baseDir: base,
    headDir: head,
    repeatDir: repeat,
    baseIds: new Set([id]),
    headIds: new Set([id]),
    outDir: join(root, "blink-diff"),
  });
  expect(outcome!.status).toBe("nondeterministic");
  expect(outcome!.frames![0]!.status).toBe("nondeterministic");
});
