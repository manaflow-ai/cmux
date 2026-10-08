// Link and path chips in replies (decision D4): what a reader sees for a path or a URL, and what
// a click asks the host for.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-page://cmux.agent/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../conversation/Markdown");
const { setChipHost } = await import("./host");
const { resetLinkStore } = await import("./linkStore");

type Inspect = { paths?: Record<string, unknown>; sites?: Record<string, unknown>; policy?: Record<string, string> };

/// Renders `source` with a host that answers `link.inspect` with `inspect` and records the rest.
async function render(source: string, inspect: Inspect = {}, answers: Record<string, unknown> = {}) {
  resetLinkStore();
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.inspect") return inspect;
    calls.push({ method, params });
    return answers[method] ?? null;
  });
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(Markdown, null, source)));
  // The batched inspect, then the render with its answer.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return {
    container,
    calls,
    unmount: async () => {
      await act(async () => root.unmount());
      setChipHost(undefined);
    },
  };
}

test("a file link is a chip: file icon, the link text, the full path in the tooltip; a click opens it in a tab", async () => {
  const { container, calls, unmount } = await render("See [the readme](/Users/ada/repo/README.md) first.");
  const chip = container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!;
  expect(chip).not.toBeNull();
  expect(chip.title).toBe("/Users/ada/repo/README.md");
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("the readme");
  expect(chip.querySelector("svg")).not.toBeNull();
  await act(async () => chip.click());
  expect(calls).toEqual([{ method: "link.openPath", params: { path: "/Users/ada/repo/README.md" } }]);
  await unmount();
});

test("a path in inline code is a chip named by its file; a line suffix is dropped for the open", async () => {
  const { container, calls, unmount } = await render("Fixed in `/Users/ada/repo/src/main.ts:42`.");
  const chip = container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!;
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("main.ts");
  expect(chip.title).toBe("/Users/ada/repo/src/main.ts");
  expect(container.querySelector("code")).toBeNull();
  await act(async () => chip.click());
  expect(calls[0]).toEqual({ method: "link.openPath", params: { path: "/Users/ada/repo/src/main.ts" } });
  await unmount();
});

test("a file:// link and a page type open through the host's path open, never in an outside app", async () => {
  const { container, calls, unmount } = await render("[report](file:///tmp/out/report.html)");
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-chip.is-path")!.click());
  expect(calls).toEqual([{ method: "link.openPath", params: { path: "/tmp/out/report.html" } }]);
  await unmount();
});

test("outside the project a chip has a lock; the host's denied, missing and text answers draw plain text", async () => {
  const source = "`/tmp/app.log`, `/Users/ada/repo/gone.ts`, `/Users/ada/notes/secret.txt` and `/Users/ada/repo/src/`";
  const paths = {
    "/tmp/app.log": { place: "outside", folder: false },
    "/Users/ada/repo/gone.ts": { place: "missing", folder: false },
    "/Users/ada/notes/secret.txt": { place: "denied", folder: false },
    "/Users/ada/repo/src/": { place: "root", folder: true },
  };
  let { container, unmount } = await render(source, { paths });
  const chips = [...container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")];
  expect(chips.map((chip) => chip.dataset.path)).toEqual(["/tmp/app.log", "/Users/ada/repo/src/"]);
  expect(chips[0]!.classList.contains("is-outside")).toBe(true);
  expect(chips[0]!.querySelectorAll("svg").length).toBe(2);
  expect(chips[0]!.title).toBe("/tmp/app.log\nOutside this project");
  expect(container.textContent).toContain("/Users/ada/repo/gone.ts");
  await unmount();
  ({ container, unmount } = await render(source, { paths, policy: { outsideRoots: "text" } }));
  expect(
    [...container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")].map((chip) => chip.dataset.path),
  ).toEqual(["/Users/ada/repo/src/"]);
  await unmount();
});

test("a web chip shows the site's favicon only when the host already has it", async () => {
  const icon = "data:image/png;base64,iVBORw0KGgo=";
  const { container, unmount } = await render("[a](https://a.example/x) and [b](https://b.example/y)", {
    sites: { "https://a.example/x": { icon } },
  });
  const chips = [...container.querySelectorAll<HTMLAnchorElement>("a.cv-chip.is-web")];
  expect(chips[0]!.querySelector("img")?.getAttribute("src")).toBe(icon);
  expect(chips[1]!.querySelector("img")).toBeNull();
  expect(chips[1]!.querySelector("svg")).not.toBeNull();
  await unmount();
});

test("a web image waits for a click by default, then shows the host's data URL", async () => {
  const data = "data:image/png;base64,iVBORw0KGgo=";
  const { container, calls, unmount } = await render(
    "![cat](https://img.example/cat.png)",
    {},
    { "image.load": { src: data } },
  );
  expect(container.querySelector("img")).toBeNull();
  expect(container.querySelector(".cv-image-placeholder__host")?.textContent).toBe("img.example");
  expect(calls).toEqual([]);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-image-placeholder__load")!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(calls).toEqual([{ method: "image.load", params: { src: "https://img.example/cat.png" } }]);
  expect(container.querySelector("img")?.getAttribute("src")).toBe(data);
  await unmount();
});

test("never keeps a web image a link; a local image inside the project loads at once", async () => {
  const data = "data:image/png;base64,AAAA";
  let { container, calls, unmount } = await render("![cat](https://img.example/cat2.png)", {
    policy: { remoteImages: "never" },
  });
  expect(container.querySelector(".cv-image-placeholder")).toBeNull();
  expect(container.querySelector("a.is-image")).not.toBeNull();
  await unmount();
  ({ container, calls, unmount } = await render("![shot](docs/shot.png)", {}, { "image.load": { src: data } }));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(calls).toEqual([{ method: "image.load", params: { src: "docs/shot.png" } }]);
  expect(container.querySelector("img")?.getAttribute("src")).toBe(data);
  await unmount();
});

test("commands, globs and bare names in code stay code", async () => {
  const { container, unmount } = await render("Run `ls /tmp`, `rm -rf /tmp/x/*.log`, `README.md` and `/usr`.");
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.querySelectorAll("code").length).toBe(4);
  await unmount();
});

test("a secret on the deny list is plain text with no action", async () => {
  const { container, calls, unmount } = await render(
    "Keys: [key](/Users/ada/.ssh/id_ed25519), `/Users/ada/repo/.env.local` and `/Users/ada/certs/server.pem`.",
  );
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.textContent).toContain("/Users/ada/repo/.env.local");
  expect(container.querySelectorAll("button").length).toBe(0);
  expect(calls).toEqual([]);
  await unmount();
});

test("a web link is a chip: globe, the link text, the full URL in the tooltip, an ordinary link", async () => {
  const { container, unmount } = await render("Read [the docs](https://example.com/guide?x=1).");
  const chip = container.querySelector<HTMLAnchorElement>("a.cv-chip.is-web")!;
  expect(chip.getAttribute("href")).toBe("https://example.com/guide?x=1");
  expect(chip.title).toBe("https://example.com/guide?x=1");
  expect(chip.querySelector(".cv-chip__label")?.textContent).toBe("the docs");
  expect(chip.querySelector("svg")).not.toBeNull();
  await unmount();
});

test("a javascript: link still draws as its text", async () => {
  const { container, unmount } = await render("[click](javascript:alert(1))");
  expect(container.querySelector("a")).toBeNull();
  expect(container.querySelector(".cv-chip")).toBeNull();
  expect(container.textContent).toBe("click");
  await unmount();
});

test("a real Claude reply: a backticked path with a space, a plain path, a bare URL and a relative link are all chips", async () => {
  const reply = [
    "The file is `/Users/cmux/Library/Application Support/cmux/agent-home/f1ff/demo.ts` here.",
    "Also /Users/cmux/hqacp-preflight/work/demo.ts as a plain path.",
    "Docs: https://example.com/docs",
    "Relative: [notes](./notes.md)",
    "Home: ~/notes/todo.md, and `~/src/app/`.",
  ].join("\n");
  const { container, calls, unmount } = await render(reply);
  const paths = [...container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")].map((chip) => chip.dataset.path);
  expect(paths).toEqual([
    "/Users/cmux/Library/Application Support/cmux/agent-home/f1ff/demo.ts",
    "/Users/cmux/hqacp-preflight/work/demo.ts",
    "./notes.md",
    "~/notes/todo.md",
    "~/src/app/",
  ]);
  const web = container.querySelector<HTMLAnchorElement>("a.cv-chip.is-web")!;
  expect(web.getAttribute("href")).toBe("https://example.com/docs");
  expect(web.textContent).toBe("https://example.com/docs");
  // The sentence around them stays: nothing is lost or doubled.
  expect(container.textContent).toContain("Also demo.ts as a plain path.");
  expect(container.textContent).toContain("Home: todo.md, and app.");
  await act(async () => container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")[2]!.click());
  expect(calls).toEqual([{ method: "link.openPath", params: { path: "./notes.md" } }]);
  await unmount();
});

test("prose that only looks like a path or a URL stays text", async () => {
  const { container, unmount } = await render("Use and/or 1/2 and http:// or a.b/c, see https://.");
  expect(container.querySelector(".cv-chip")).toBeNull();
  await unmount();
});

test("a backticked path whose file name holds a space is a chip, also from home", async () => {
  const { container, unmount } = await render(
    "See `/Users/x/Library/Application Support/cmux/spaced demo.ts` and `~/My Notes/to do.md`.",
  );
  expect(
    [...container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")].map((chip) => chip.dataset.path),
  ).toEqual(["/Users/x/Library/Application Support/cmux/spaced demo.ts", "~/My Notes/to do.md"]);
  expect(container.querySelector("code")).toBeNull();
  await unmount();
});

/// The reply from Lawrence's screenshot (2026-10-06): the fleet status files in /tmp, outside the
/// session's folders.
const FLEET_REPLY = [
  "Rendered the build fleet status: `/tmp/fleetviz/out/fleet.png` and `/tmp/fleetviz/out/fleet.html`.",
  "",
  "![Build fleet status](/tmp/fleetviz/out/fleet.png)",
].join("\n");
const FLEET_PATHS = {
  "/tmp/fleetviz/out/fleet.png": { place: "outside", folder: false },
  "/tmp/fleetviz/out/fleet.html": { place: "outside", folder: false },
};

test("the fleet reply: both backticked /tmp paths are outside chips (lock, bold name, full path on hover)", async () => {
  const { container, calls, unmount } = await render(FLEET_REPLY, { paths: FLEET_PATHS });
  const chips = [...container.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")];
  expect(chips.map((chip) => chip.dataset.path)).toEqual([
    "/tmp/fleetviz/out/fleet.png",
    "/tmp/fleetviz/out/fleet.html",
  ]);
  expect(chips.map((chip) => chip.querySelector(".cv-chip__label")?.textContent)).toEqual(["fleet.png", "fleet.html"]);
  for (const chip of chips) {
    expect(chip.classList.contains("is-outside")).toBe(true);
    expect(chip.querySelector(".cv-chip__lock")).not.toBeNull();
    expect(chip.title.startsWith(chip.dataset.path!)).toBe(true);
  }
  expect(container.querySelector("code")).toBeNull();
  await act(async () => chips[1]!.click());
  expect(calls.filter((call) => call.method === "link.openPath")).toEqual([
    { method: "link.openPath", params: { path: "/tmp/fleetviz/out/fleet.html" } },
  ]);
  await unmount();
});

test("one path detector: prose, code spans and links chip the same forms (file URLs, folders, ./ paths)", async () => {
  const reply = [
    "Prose: file:///tmp/fleetviz/out/fleet.html, the folder /tmp/fleetviz/out/ and ./docs/notes.md.",
    "Code: `file:///tmp/fleetviz/out/fleet.html`, `/tmp/fleetviz/out/` and `./docs/notes.md`.",
    "Links: [page](file:///tmp/fleetviz/out/fleet.html), [out](/tmp/fleetviz/out/) and [notes](./docs/notes.md).",
  ].join("\n");
  const { container, unmount } = await render(reply);
  const lines = [...container.querySelectorAll("p")].flatMap((p) => p.innerHTML.split("<br>"));
  const paths = (html: string) => {
    const div = dom.window.document.createElement("div");
    div.innerHTML = html;
    return [...div.querySelectorAll<HTMLButtonElement>(".cv-chip.is-path")].map((chip) => chip.dataset.path);
  };
  const expected = ["/tmp/fleetviz/out/fleet.html", "/tmp/fleetviz/out/", "./docs/notes.md"];
  expect(lines.map(paths)).toEqual([expected, expected, expected]);
  expect(container.querySelector("code")).toBeNull();
  expect(container.textContent).toContain("Prose: fleet.html, the folder out and notes.md.");
  await unmount();
});

test("the fleet reply's /tmp image, outside the folders: its alt text, its file name and Open, never a broken image", async () => {
  const { container, calls, unmount } = await render(FLEET_REPLY, { paths: FLEET_PATHS });
  const card = container.querySelector<HTMLElement>(".cv-image-file")!;
  expect(card).not.toBeNull();
  expect(container.querySelector("img")).toBeNull();
  expect(card.querySelector(".cv-image-file__alt")?.textContent).toBe("Build fleet status");
  expect(card.querySelector(".cv-image-file__name")?.textContent).toBe("fleet.png");
  expect(card.querySelector(".cv-chip__lock")).not.toBeNull();
  expect(card.title).toBe("/tmp/fleetviz/out/fleet.png\nOutside this project");
  // The host refuses a load outside the folders, so the page does not ask.
  expect(calls.filter((call) => call.method === "image.load")).toEqual([]);
  const open = card.querySelector<HTMLButtonElement>("button")!;
  expect(open.textContent).toBe("Open");
  await act(async () => open.click());
  expect(calls).toEqual([{ method: "link.openPath", params: { path: "/tmp/fleetviz/out/fleet.png" } }]);
  await unmount();
});

test("an outside image under outsideRoots text has no Open; a missing one says so; a denied one is plain text", async () => {
  let { container, unmount } = await render(FLEET_REPLY, { paths: FLEET_PATHS, policy: { outsideRoots: "text" } });
  expect(container.querySelector(".cv-image-file__name")?.textContent).toBe("fleet.png");
  expect(container.querySelector(".cv-image-file button")).toBeNull();
  await unmount();
  ({ container, unmount } = await render("![chart](/Users/ada/repo/out/chart.png)", {
    paths: { "/Users/ada/repo/out/chart.png": { place: "missing", folder: false } },
  }));
  expect(container.querySelector(".cv-image-file__note")?.textContent).toBe("Image unavailable");
  expect(container.querySelector(".cv-image-file button")).toBeNull();
  await unmount();
  ({ container, unmount } = await render("![key](/Users/ada/certs/server.pem)"));
  expect(container.querySelector(".cv-image-file")).toBeNull();
  expect(container.querySelectorAll("button").length).toBe(0);
  expect(container.textContent).toBe("key");
  await unmount();
});

test("a local image the host will not load shows the same compact state with Open", async () => {
  const { container, calls, unmount } = await render("![shot](/Users/ada/repo/shot.png)", {
    paths: { "/Users/ada/repo/shot.png": { place: "root", folder: false } },
  });
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(calls).toEqual([{ method: "image.load", params: { src: "/Users/ada/repo/shot.png" } }]);
  expect(container.querySelector(".cv-image-file__name")?.textContent).toBe("shot.png");
  expect(container.querySelector(".cv-image-file__note")?.textContent).toBe("Image unavailable");
  expect(container.querySelector(".cv-image-file button")?.textContent).toBe("Open");
  await unmount();
});
