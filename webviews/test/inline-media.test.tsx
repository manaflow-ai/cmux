// Screenshots, commits, `hq#N` and `file:line` in agent replies (Leo 2026-10-21: "you should've just
// added images or some kind of link inline"). Every form an agent writes an image in draws as a
// thumbnail in a fixed glass frame, two in a row sit side by side, and the other references link.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { bareImageSource, imageOnlyItems, proseImages } from "../src/agent-session/acpmux/conversation/inlineMedia";
import { codePath, isImagePath, isImageUrl, textLinks } from "../src/agent-session/acpmux/chips/paths";
import { commitReferences, githubReferences, mentionedRepository } from "../src/githubReferences";

const REPO = "manaflow-ai/cmux";
const PR_MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/23650/tabs-light.png";
const LOCAL_TMP = "/tmp/cx-lanes/sidebar-clean-cmux.png";
const OUTSIDE_IMAGE = "/var/tmp/other-host/sidebar-clean-cmux.png";

describe("image-only paragraphs", () => {
  const cases: Array<[name: string, text: string, items: Array<[src: string, alt: string]> | undefined]> = [
    ["Markdown image, absolute path", "![Before](/tmp/a.png)", [["/tmp/a.png", "Before"]]],
    [
      "two Markdown images on one line",
      "![Before](/tmp/a.png) ![After](/tmp/b.png)",
      [
        ["/tmp/a.png", "Before"],
        ["/tmp/b.png", "After"],
      ],
    ],
    [
      "two Markdown images on two lines",
      "![Before](/tmp/a.png)\n![After](/tmp/b.png)",
      [
        ["/tmp/a.png", "Before"],
        ["/tmp/b.png", "After"],
      ],
    ],
    [
      "labelled bare paths",
      "Before: /tmp/a.png\nAfter: /tmp/b.png",
      [
        ["/tmp/a.png", "Before"],
        ["/tmp/b.png", "After"],
      ],
    ],
    [
      "bold labels on Markdown images",
      "**Before:** ![](/tmp/a.png) **After:** ![](/tmp/b.png)",
      [
        ["/tmp/a.png", "Before"],
        ["/tmp/b.png", "After"],
      ],
    ],
    ["file URL", "file:///tmp/shots/a.png", [["file:///tmp/shots/a.png", ""]]],
    ["home path", "~/Desktop/shot.jpeg", [["~/Desktop/shot.jpeg", ""]]],
    ["pr-media address", PR_MEDIA, [[PR_MEDIA, ""]]],
    ["https image as a Markdown image", `![Tabs](${PR_MEDIA})`, [[PR_MEDIA, "Tabs"]]],
    ["data URL image", "![dot](data:image/png;base64,AAAA)", [["data:image/png;base64,AAAA", "dot"]]],
    ["a sentence is not image-only", "See /tmp/a.png for the result", undefined],
    [
      "a sentence ending in a colon is prose, not a label",
      "I saved the new sidebar screenshot here: /tmp/a.png",
      undefined,
    ],
    ["a sentence before a Markdown image is prose", "Here is what it looks like now: ![](/tmp/a.png)", undefined],
    ["a two-word label", "Dark mode: /tmp/a.png", [["/tmp/a.png", "Dark mode"]]],
    ["an underscored label", "__Before__: /tmp/a.png", [["/tmp/a.png", "Before"]]],
    ["a bold label with the colon outside", "**After**: /tmp/a.png", [["/tmp/a.png", "After"]]],
    ["a non-image path", "/tmp/build.log", undefined],
    ["a deny-listed image", "~/.ssh/key.png", undefined],
    ["a plain http image", "http://example.com/a.png", undefined],
    ["a web page", "https://example.com/page", undefined],
    ["a path with a line suffix", "/tmp/a.png:3", undefined],
  ];
  test.each(cases)("%s", (_name, text, items) => {
    expect(imageOnlyItems(text)?.map((item) => [item.src, item.alt])).toEqual(items);
  });
});

describe("image paths in a sentence", () => {
  test("an absolute path and an https image are found once each, in order", () => {
    expect(proseImages(`Saved /tmp/a.png and ${PR_MEDIA}, then /tmp/a.png again.`).map((item) => item.src)).toEqual([
      "/tmp/a.png",
      PR_MEDIA,
    ]);
  });
  test("code spans, link targets and Markdown images are not prose", () => {
    expect(proseImages("Run `open /tmp/a.png`, see [it](/tmp/b.png) and ![c](/tmp/c.png).")).toEqual([]);
  });
  test("a path with a line suffix or another extension is not an image", () => {
    expect(proseImages("Look at /tmp/a.png:3 and /tmp/notes.md")).toEqual([]);
  });
  test("bareImageSource accepts only image tokens", () => {
    expect(bareImageSource("/tmp/a.webp")).toBe("/tmp/a.webp");
    expect(bareImageSource("./shots/a.GIF")).toBe("./shots/a.GIF");
    expect(bareImageSource("a.png")).toBeUndefined();
    expect(bareImageSource("https://x.test/a.png?raw=1")).toBe("https://x.test/a.png?raw=1");
    expect(isImagePath("/tmp/a.svg")).toBe(false);
    expect(isImageUrl("https://x.test/a.jpg#frag")).toBe(true);
  });
});

describe("long untrusted text stays fast", () => {
  test("base64 and `a+b/` runs scan in linear time", () => {
    const base64 = `${"iVBORw0KGgoAAAANSUhEUgAA+/".repeat(10_000)}x`;
    const plus = "lib+1/x".repeat(5_000);
    const slashes = `${"+/a".repeat(20_000)}x`;
    const started = performance.now();
    textLinks(base64);
    textLinks(plus);
    textLinks(slashes);
    proseImages(`see ${base64}`);
    expect(performance.now() - started).toBeLessThan(500);
  });
});

describe("file:line references", () => {
  test("a relative path with a line is a path chip that keeps its line", () => {
    const [link] = textLinks("fails at webviews/src/app.ts:42:7, see there");
    expect(link).toMatchObject({
      kind: "path",
      path: "webviews/src/app.ts",
      location: { line: 42, column: 7 },
      value: "webviews/src/app.ts:42:7",
    });
  });
  test("an absolute path keeps its line too", () => {
    expect(textLinks("at /Users/you/x/retry.ts:12.")[0]).toMatchObject({
      path: "/Users/you/x/retry.ts",
      location: { line: 12 },
    });
  });
  test("a domain is not a folder", () => {
    expect(textLinks("example.com/app.js:1")).toEqual([]);
  });
  test("a code span with a relative file:line is a path", () => {
    expect(codePath("Packages/macOS/Foo.swift:120")).toBe("Packages/macOS/Foo.swift");
    expect(codePath(".github/workflows/ci.yml:3")).toBe(".github/workflows/ci.yml");
    expect(codePath("git log -1")).toBeUndefined();
  });
});

describe("repository aliases and commits", () => {
  test("hq#N links to cmuxterm-hq; another word glued to # stays text", () => {
    expect(githubReferences("see hq#2713 and foo#12", REPO, "pull", true).map((ref) => [ref.text, ref.href])).toEqual([
      ["hq#2713", "https://github.com/manaflow-ai/cmuxterm-hq/pull/2713"],
    ]);
  });
  test("aliases are for agent replies only; the document editor and prototype keys never link", () => {
    expect(githubReferences("see hq#2713", REPO)).toEqual([]);
    expect(githubReferences("constructor#1 and toString#2", REPO, "pull", true)).toEqual([]);
  });
  test("an alias never becomes the transcript's repository", () => {
    expect(mentionedRepository("see hq#2713")).toBeUndefined();
    expect(mentionedRepository("a/b#1 then hq#2")).toBe("a/b");
  });
  const commits: Array<[name: string, text: string, refs: Array<[text: string, href: string]>]> = [
    ["short SHA", "landed at 2f1920a.", [["2f1920a", `https://github.com/${REPO}/commit/2f1920a`]]],
    [
      "full SHA",
      "head 2f1920a175e3c0d6a1b2c3d4e5f60718293a4b5c",
      [
        [
          "2f1920a175e3c0d6a1b2c3d4e5f60718293a4b5c",
          `https://github.com/${REPO}/commit/2f1920a175e3c0d6a1b2c3d4e5f60718293a4b5c`,
        ],
      ],
    ],
    ["qualified", "owner/repo@abc1234", [["owner/repo@abc1234", "https://github.com/owner/repo/commit/abc1234"]]],
    ["a hex word with no digit", "deadbeef cafebabe", []],
    ["digits only", "1234567 and 20261021", []],
    ["a color", "#a1b2c3d", []],
    ["a hex number", "0xabc1234", []],
    ["a digest", `sha256:${"a1".repeat(32)}`, []],
    ["inside a URL path", "https://x.test/abc1234", []],
    ["glued to a word", "vabc1234 abc1234x", []],
  ];
  test.each(commits)("commit: %s", (_name, text, refs) => {
    expect(commitReferences(text, REPO).map((ref) => [ref.text, ref.href])).toEqual(refs);
  });
  test("a bare SHA needs a repository", () => {
    expect(commitReferences("at 2f1920a")).toEqual([]);
  });
});

describe("rendered replies", () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "IS_REACT_ACT_ENVIRONMENT",
  ] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  beforeAll(() => {
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      HTMLElement: dom.window.HTMLElement,
      Element: dom.window.Element,
      Node: dom.window.Node,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
  });
  afterAll(() => {
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  });

  const IMAGE = "data:image/png;base64,iVBORw0KGgo=";
  const loads: string[] = [];
  const CLICK_FREE = ["raw.githubusercontent.com"];
  async function render(
    markdown: string,
    host: "answer" | "silent" | "refuse" = "answer",
    clickFreeImageHosts: string[] = [],
  ) {
    const { act } = await import("react");
    const { createRoot } = await import("react-dom/client");
    const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
    const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    resetLinkStore();
    seedLinkStore({
      paths: {
        "/tmp/shots/before.png": { place: "root", folder: false },
        "/tmp/shots/after.png": { place: "root", folder: false },
        "/tmp/shots/slow.png": { place: "root", folder: false },
        [LOCAL_TMP]: { place: "root", folder: false },
        [OUTSIDE_IMAGE]: { place: "outside", folder: false },
      },
      policy: { remoteImages: "click", outsideRoots: "confirm", clickFreeImageHosts },
    });
    loads.length = 0;
    setChipHost(async (method, params) => {
      if (method === "image.load") loads.push(params.auto === true ? `auto ${String(params.src)}` : String(params.src));
      if (method === "image.load" && host === "refuse" && params.auto === true) return undefined;
      if (method === "image.load" && host !== "silent") return { src: IMAGE };
      if (method === "image.load") return new Promise(() => {});
      return {};
    });
    const container = dom.window.document.createElement("div");
    dom.window.document.body.append(container);
    const root = createRoot(container);
    await act(async () => root.render(<Markdown githubRepository={REPO}>{markdown}</Markdown>));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    return { container, unmount: () => act(async () => root.unmount()) };
  }

  test("a before/after pair draws side by side, captioned, each in a glass thumbnail", async () => {
    const { container, unmount } = await render("![Before](/tmp/shots/before.png) ![After](/tmp/shots/after.png)");
    const row = container.querySelector(".cv-thumbs.is-row");
    expect(row).not.toBeNull();
    expect(row!.querySelectorAll(".cv-thumb img.cv-thumb__img").length).toBe(2);
    expect([...row!.querySelectorAll(".cv-thumbs__caption")].map((caption) => caption.textContent)).toEqual([
      "Before",
      "After",
    ]);
    await unmount();
  });

  test("a local /tmp image loads into its thumbnail", async () => {
    const { container, unmount } = await render(`![Sidebar](${LOCAL_TMP})`);
    expect(container.querySelector(".cv-thumb img.cv-thumb__img")).not.toBeNull();
    expect(container.querySelector(".cv-image-file")).toBeNull();
    expect(loads).toEqual([LOCAL_TMP]);
    await unmount();
  });

  test("an image outside the local image roots stays gated", async () => {
    const { container, unmount } = await render(`![Sidebar](${OUTSIDE_IMAGE})`);
    expect(container.querySelector(".cv-thumb img.cv-thumb__img")).toBeNull();
    expect(container.querySelector(".cv-image-file.is-outside")).not.toBeNull();
    expect(container.querySelector(".cv-chip__lock")).not.toBeNull();
    expect(loads).toEqual([]);
    await unmount();
  });

  test("an image still loading keeps its thumbnail frame, so nothing moves when it lands", async () => {
    const { container, unmount } = await render("![Slow](/tmp/shots/slow.png)", "silent");
    expect(container.querySelector(".cv-thumb.is-waiting")).not.toBeNull();
    expect(container.querySelector("img")).toBeNull();
    await unmount();
  });

  test("a pr-media address waits for Load image inside the frame when the host names no click-free site", async () => {
    const { container, unmount } = await render(`![Tabs](${PR_MEDIA})`);
    expect(container.querySelector(".cv-thumb.is-placeholder .cv-image-placeholder__load")).not.toBeNull();
    expect(loads).toEqual([]);
    await unmount();
  });

  test("a before/after pair from pr-media draws inline side by side with no click (its site is click-free)", async () => {
    // Leo 2026-10-23, of a pair whose second image waited on Load image: "i feel like this is a bit lame idk".
    const before = PR_MEDIA.replace("tabs-light", "before"),
      after = PR_MEDIA.replace("tabs-light", "after");
    const { container, unmount } = await render(`![](${before}) ![](${after})`, "answer", CLICK_FREE);
    const row = container.querySelector(".cv-thumbs.is-row");
    expect(row!.querySelectorAll(".cv-thumb img.cv-thumb__img").length).toBe(2);
    expect(container.querySelector(".cv-image-placeholder__load")).toBeNull();
    // Each asks as the page's own load, so a refusal spends no click.
    expect(loads).toEqual([`auto ${before}`, `auto ${after}`]);
    await unmount();
  });

  test("a click-free image the host refuses waits for its Load image, which then loads it", async () => {
    const src = PR_MEDIA.replace("tabs-light", "refused");
    const { container, unmount } = await render(`![](${src})`, "refuse", CLICK_FREE);
    const button = container.querySelector<HTMLButtonElement>(".cv-image-placeholder__load");
    expect(button).not.toBeNull();
    expect(container.querySelector(".cv-image-placeholder__note")).toBeNull();
    const { act } = await import("react");
    await act(async () => button!.click());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(container.querySelector(".cv-thumb img.cv-thumb__img")).not.toBeNull();
    expect(loads).toEqual([`auto ${src}`, src]);
    await unmount();
  });

  test("an image from another site still waits for Load image while raw.githubusercontent.com is click-free", async () => {
    const others = [
      "https://images.example.com/chart.png",
      "https://github.com/o/r/releases/download/v1/chart.png",
      "https://raw.githubusercontent.com.evil.example/chart.png",
      "http://raw.githubusercontent.com/o/r/main/chart.png",
    ];
    for (const src of others) {
      const { container, unmount } = await render(`![Chart](${src})`, "answer", CLICK_FREE);
      expect(container.querySelector("img")).toBeNull();
      await unmount();
    }
    expect(loads).toEqual([]);
  });

  test("an image path in a sentence stays a chip, with its thumbnail under the paragraph", async () => {
    const { container, unmount } = await render("Saved the screenshot to /tmp/shots/before.png for review.");
    const [prose, images] = [...container.querySelectorAll("p")];
    expect(prose!.querySelector(".cv-chip.is-path")).not.toBeNull();
    expect(images!.querySelector(".cv-thumb img")).not.toBeNull();
    await unmount();
  });

  test("a sentence ending in a colon keeps its text; its image draws under it", async () => {
    const { container, unmount } = await render("I saved the new screenshot here: /tmp/shots/before.png");
    expect(container.textContent).toContain("I saved the new screenshot here:");
    expect(container.querySelector(".cv-thumb img")).not.toBeNull();
    await unmount();
  });

  test("a label alone on its line is the caption of its one image", async () => {
    const { container, unmount } = await render("After: /tmp/shots/after.png");
    expect(container.querySelector(".cv-thumbs__caption")?.textContent).toBe("After");
    await unmount();
  });

  test("a commit inside a URL stays part of the URL's chip", async () => {
    const { container, unmount } = await render("Loaded https://cdn.example.com/app.js?v=3a7bd3e2 fine.");
    const hrefs = [...container.querySelectorAll("a")].map((anchor) => anchor.getAttribute("href"));
    expect(hrefs).toEqual(["https://cdn.example.com/app.js?v=3a7bd3e2"]);
    await unmount();
  });

  test("a commit, hq#N and a relative file:line are links", async () => {
    const { container, unmount } = await render("Fixed in 2f1920a (hq#2713), see webviews/src/app.ts:42.");
    const hrefs = [...container.querySelectorAll("a")].map((anchor) => anchor.getAttribute("href"));
    expect(hrefs).toEqual([
      `https://github.com/${REPO}/commit/2f1920a`,
      "https://github.com/manaflow-ai/cmuxterm-hq/pull/2713",
    ]);
    const path = container.querySelector<HTMLElement>(".cv-chip.is-path");
    expect(path?.dataset.path).toBe("webviews/src/app.ts");
    expect(path?.textContent).toBe("app.ts:42");
    await unmount();
  });
});
