// l10n-allow-file: test fixtures.
// Every file another agent's message names is written out in full before it draws, so each is a
// chip that opens it (messageFiles.ts).
import { expect, test } from "bun:test";
import {
  joinPath,
  messageFiles,
  messageFileText,
  messageImages,
  messageImagesHeight,
  MESSAGE_THUMB,
} from "./messageFiles";
import { layoutConversation, RECEIVED_LINES } from "../model";
import { textLinks } from "../chips/paths";
import { proseImages } from "./inlineMedia";

const paths = (text: string) => textLinks(text).flatMap((link) => (link.kind === "path" ? [link.path] : []));

test("bare file names after a full path are files in its folder", () => {
  const text =
    "Screenshots: /tmp/lane/before-queued.png, after-queued-agent-line.png, after-queued-agent-open.png (cosmic-gray).";
  const full = messageFileText(text, undefined);
  expect(paths(full)).toEqual([
    "/tmp/lane/before-queued.png",
    "/tmp/lane/after-queued-agent-line.png",
    "/tmp/lane/after-queued-agent-open.png",
  ]);
  // Each is an image, so each draws a thumbnail too.
  expect(proseImages(full).map((item) => item.src)).toHaveLength(3);
});

test("Leo's screenshot: a home path then two bare names joined by a slash", () => {
  const text =
    "Before: ~/shots/chromium-base-see-through.png. After: chromium-fixed-see-through.png / chromium-fixed-opaque.png";
  expect(paths(messageFileText(text, undefined))).toEqual([
    "~/shots/chromium-base-see-through.png",
    "~/shots/chromium-fixed-see-through.png",
    "~/shots/chromium-fixed-opaque.png",
  ]);
});

test("a bare name with no full path before it is a file in the sender's folder", () => {
  expect(paths(messageFileText("Wrote notes.md and shot.png.", "/home/leo/lane"))).toEqual([
    "/home/leo/lane/notes.md",
    "/home/leo/lane/shot.png",
  ]);
  // Without the sender's folder it stays as written: there is nothing to open.
  expect(messageFileText("Wrote notes.md and shot.png.", undefined)).toBe("Wrote notes.md and shot.png.");
});

test("relative paths are files in the sender's folder; ./ and ../ resolve", () => {
  const text = "Changed webviews/src/model.ts and ./docs/plan.md; see ../shared/a.log too.";
  expect(paths(messageFileText(text, "/w/cmux/"))).toEqual([
    "/w/cmux/webviews/src/model.ts",
    "/w/cmux/docs/plan.md",
    "/w/shared/a.log",
  ]);
  // A relative path never takes the folder of a full path before it: it is the sender's.
  expect(paths(messageFileText("/tmp/x/a.png then src/b.ts", "/repo"))).toEqual(["/tmp/x/a.png", "/repo/src/b.ts"]);
});

test("a code span that is one name is written out and stays code; other code is untouched", () => {
  expect(messageFileText("Saved /tmp/a/one.png and `two.png`.", undefined)).toBe(
    "Saved /tmp/a/one.png and `/tmp/a/two.png`.",
  );
  expect(messageFileText("Run `ls two.png | wc` now", "/repo")).toBe("Run `ls two.png | wc` now");
  const fenced = "/tmp/a/x.png\n```\ncat y.png\n```\nz.png";
  expect(messageFileText(fenced, undefined)).toBe("/tmp/a/x.png\n```\ncat y.png\n```\n/tmp/a/z.png");
});

test("words, addresses, references and source names stay text", () => {
  for (const text of [
    "Node.js and e.g. v1.2 are words; so is model.ts.",
    "See example.com/a.md and https://x.test/b.png.",
    "Merged manaflow-ai/cmux#23825 at owner/repo@abc1234.",
    "an email leo@example.com",
  ])
    expect(messageFileText(text, "/repo")).toBe(text);
});

test("a link's target starts the folder of the bare names after it, and is never rewritten", () => {
  expect(messageFileText("[before](/tmp/s/a.png) and b.png", undefined)).toBe(
    "[before](/tmp/s/a.png) and /tmp/s/b.png",
  );
});

test("a bare name takes a full path's folder only when it is the same kind of file", () => {
  expect(messageFileText("Shot: /tmp/x/a.png. Updated CHANGELOG.md", undefined)).toBe(
    "Shot: /tmp/x/a.png. Updated CHANGELOG.md",
  );
  expect(messageFileText("Shot: /tmp/x/a.png. Updated CHANGELOG.md", "/repo")).toBe(
    "Shot: /tmp/x/a.png. Updated /repo/CHANGELOG.md",
  );
  expect(paths(messageFileText("Plan /tmp/x/plan.md, then notes.md; folder /tmp/y/ has b.log", undefined))).toEqual([
    "/tmp/x/plan.md",
    "/tmp/x/notes.md",
    "/tmp/y/",
    "/tmp/y/b.log",
  ]);
});

test("each name written out keeps the agent's spelling", () => {
  const { text, written } = messageFiles("Shots: /tmp/x/a.png, b.png; `c.png`; src/d.ts:4", "/repo");
  expect(text).toBe("Shots: /tmp/x/a.png, /tmp/x/b.png; `/tmp/x/c.png`; /repo/src/d.ts:4");
  expect([...written]).toEqual([
    ["/tmp/x/b.png", "b.png"],
    ["/tmp/x/c.png", "c.png"],
    ["/repo/src/d.ts:4", "src/d.ts:4"],
  ]);
  // A folder with `$` in it is written as it is.
  expect(messageFileText("`c.png`", "/w/$&x")).toBe("`/w/$&x/c.png`");
});

test("options, variables, Windows paths and reference links stay as written", () => {
  for (const text of [
    "Shot /tmp/x/a.png; also C:\\Users\\b.png and --out=c.png",
    "Shot /tmp/x/a.png; @user.md, +x.md, -y.md, $HOME.md and %TEMP%.png",
    "Shot /tmp/x/a.png and [shot.png][1]",
  ])
    expect(messageFileText(text, "/repo")).toBe(text);
});

test("a name after a letter outside ASCII is part of a word, never split", () => {
  for (const text of ["/tmp/x/a.png then über.png", "/tmp/x/a.md and naïve_notes.md", "/tmp/ü/a.png"])
    expect(messageFileText(text, "/repo")).toBe(text);
});

test("a file's first spelling is the one its chip falls back to", () => {
  expect([...messageFiles("Shot /tmp/x/b.png, then b.png", undefined).written]).toEqual([]);
  expect([...messageFiles("Shots: /tmp/x/a.png, b.png; again /tmp/x/b.png", undefined).written]).toEqual([
    ["/tmp/x/b.png", "b.png"],
  ]);
});

test("a home folder starts the folder of the names after it", () => {
  expect(messageFileText("in ~/: shot.png", "/repo")).toBe("in ~/: ~/shot.png");
  expect(messageFileText("Wrote shot.png", "~")).toBe("Wrote ~/shot.png");
});

test("a message naming many files is read once", () => {
  const text = Array.from({ length: 100000 }, (_, i) => `/tmp/x/a${i}.png b${i}.png`).join(" ");
  const started = performance.now();
  messageFiles(text, "/repo");
  expect(performance.now() - started).toBeLessThan(2000);
});

test("a long run without a space is passed over quickly", () => {
  for (const text of ["x".repeat(40000) + ".pn", "a.".repeat(20000), `see ${"b".repeat(5000)}.png and /tmp/x/a.png`]) {
    const started = performance.now();
    expect(messageFileText(text, "/repo")).toBe(text);
    expect(performance.now() - started).toBeLessThan(200);
  }
  // Names around it are still written out.
  expect(messageFileText(`/tmp/x/a.png ${"z".repeat(600)} b.png`, undefined)).toBe(
    `/tmp/x/a.png ${"z".repeat(600)} /tmp/x/b.png`,
  );
});

test("joinPath resolves . and .. and keeps home", () => {
  expect(joinPath("/a/b", "../c/./d.png")).toBe("/a/c/d.png");
  expect(joinPath("~/x", "y.md")).toBe("~/x/y.md");
  expect(joinPath("~", "../y.md")).toBe("~/y.md");
});

test("a message's images are its image paths in prose and in one-path code spans, once each", () => {
  const text = [
    "Before: /tmp/s/a.png, after `/tmp/s/b.png`; again /tmp/s/a.png.",
    "```",
    "/tmp/s/fenced.png",
    "```",
    "Not code: `cp /tmp/s/c.png x` nor a link's [text](/tmp/s/d.png) nor /tmp/s/e.ts.",
  ].join("\n");
  expect(messageImages(text).map((item) => item.src)).toEqual(["/tmp/s/a.png", "/tmp/s/b.png"]);
});

test("the strip's estimate wraps its thumbnails to the card's width", () => {
  const { width, height, gap } = MESSAGE_THUMB;
  expect(messageImagesHeight(0, 600)).toBe(0);
  expect(messageImagesHeight(3, 600)).toBe(gap + height);
  expect(messageImagesHeight(3, width * 2 + gap)).toBe(gap + 2 * height + gap);
  // The row's estimate grows by the strip: a message naming three screenshots, against the same
  // message naming none.
  const row = (text: string) => ({
    id: "m",
    version: 1,
    at: 0,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "lane", text, raw: text } },
  });
  const heights = (text: string) => layoutConversation([row(text)] as never, 720).heights[0]!;
  const shots = "Screenshots: /tmp/s/a.png, b.png, c.png.";
  const plain = "Screenshots: /tmp/s/a.txt, b.txt, c.txt.";
  expect(heights(shots) - heights(plain)).toBe(messageImagesHeight(3, 720 - 46));
  expect(RECEIVED_LINES).toBe(6);
});
