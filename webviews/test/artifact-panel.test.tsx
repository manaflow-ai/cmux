// A reply's document in the side panel (cx-ncc.63, Claude parity): an HTML, SVG or Markdown fence has
// an Open button that opens it in the panel beside the chat; the panel draws its preview with the
// source a tab away, copies it, and closes on its button or Escape.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// The code card's highlighter (@pierre/diffs) defines its elements, which read DOM constructors, on import.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const window = dom.window;
const host = window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const button = (label: string) =>
  [...host.querySelectorAll("button")].find(
    (element) => element.getAttribute("aria-label") === label || element.textContent?.trim() === label,
  );

test("an HTML, SVG or Markdown fence opens in the side panel; other code has no Open", async () => {
  const { createRoot } = await import("react-dom/client");
  const { OpenPreview } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const opened: unknown[] = [];
  const draw = (lang: string, code: string) =>
    act(() =>
      root!.render(
        <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
          <OpenPreview lang={lang} code={code} />
        </ArtifactContext.Provider>,
      ),
    );

  root = createRoot(host);
  draw("html", "<h1>Hi</h1>");
  act(() => button("Open preview")!.click());
  expect(opened).toEqual([{ kind: "html", lang: "html", code: "<h1>Hi</h1>" }]);

  // An `xml` fence that holds one SVG image is an SVG.
  draw("xml", '<svg viewBox="0 0 4 4"><circle r="2"/></svg>');
  act(() => button("Open preview")!.click());
  expect(opened.at(-1)).toMatchObject({ kind: "svg" });

  draw("python", "print('hi')");
  expect(button("Open preview")).toBeUndefined();
});

test("the panel previews Markdown, shows its source on Code, copies it and closes on Escape", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  let closed = 0;
  const code = "# Release notes\n\nRetry now backs off.";

  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "markdown", lang: "markdown", code }} onClose={() => closed++} />),
  );
  const panel = host.querySelector("aside")!;
  expect(panel.getAttribute("aria-label")).toBe("Document preview");
  expect(panel.querySelector("h1")?.textContent).toBe("Release notes");
  expect(button("Preview")?.getAttribute("aria-pressed")).toBe("true");

  act(() => button("Code")!.click());
  expect(button("Code")?.getAttribute("aria-pressed")).toBe("true");
  expect(panel.querySelector("h1")).toBeNull();

  await act(async () => button("Copy")!.click());
  expect(copied).toEqual([code]);

  act(() => button("Close preview")!.click());
  expect(closed).toBe(1);
  act(() => {
    panel.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(2);
});

test("HTML on a page without the render frame shows its source only", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code: "<p>Hello</p>" }} onClose={() => {}} />),
  );
  // The test page is not the bundled pane (`cmux-agent:`), so nothing can frame the HTML.
  expect(button("Preview")).toBeUndefined();
  expect(host.querySelector("iframe")).toBeNull();
});

test("Save hands the document to the host's save panel under its title, and says Saved", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const asked: [string, string, string][] = [];
  let answer: "saved" | "cancelled" = "cancelled";
  const save = async (text: string, suggestedName: string, kind: string) => {
    asked.push([text, suggestedName, kind]);
    return answer;
  };
  const draw = (artifact: { kind: "html" | "svg" | "markdown"; lang: string; code: string; path?: string }) => {
    act(() => root?.unmount());
    root = createRoot(host);
    act(() => root!.render(<ArtifactPanel artifact={artifact} onClose={() => {}} onSave={save} />));
  };

  // A Markdown document is named by its first heading; a cancelled panel changes nothing.
  draw({ kind: "markdown", lang: "md", code: "Intro\n\n## Release notes: v2\n\nRetry backs off." });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)).toEqual(["Intro\n\n## Release notes: v2\n\nRetry backs off.", "Release notes: v2", "markdown"]);
  expect(button("Save")).toBeDefined();

  // An HTML page by its <title>, and a saved file says so.
  answer = "saved";
  const page = "<html><head><title> Pro plan </title></head><body>Hi</body></html>";
  draw({ kind: "html", lang: "html", code: page });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)).toEqual([page, "Pro plan", "html"]);
  expect(button("Saved")).toBeDefined();

  // A document with no title: the host names it.
  draw({ kind: "svg", lang: "svg", code: "<svg/>" });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)).toEqual(["<svg/>", "", "svg"]);

  // A completed file write keeps its filename when the document has no title.
  draw({ kind: "html", lang: "html", code: "<p>Counter</p>", path: "/project/previews/counter.html" });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)).toEqual(["<p>Counter</p>", "counter.html", "html"]);

  // A `#` line in a code fence is not the title; a heading keeps a real trailing `#`; a title's
  // entities read as text.
  draw({ kind: "markdown", lang: "md", code: "```sh\n# install deps\n```\n\n## Learn C#\n" });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)?.[1]).toBe("Learn C#");
  draw({ kind: "html", lang: "html", code: "<title>Tom &amp; Jerry</title>" });
  await act(async () => button("Save")!.click());
  expect(asked.at(-1)?.[1]).toBe("Tom & Jerry");

  // A host that cannot write it: the document is copied instead.
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactPanel
        artifact={{ kind: "svg", lang: "svg", code: "<svg/>" }}
        onClose={() => {}}
        onSave={async () => "unavailable"}
      />,
    ),
  );
  await act(async () => button("Save")!.click());
  expect(copied).toEqual(["<svg/>"]);
  expect(button("Copied")).toBeDefined();

  // Without a host save panel there is no Save.
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ArtifactPanel artifact={{ kind: "svg", lang: "svg", code: "<svg/>" }} onClose={() => {}} />));
  expect(button("Save")).toBeUndefined();
});

// A document's versions (cx-ncc.64, Claude parity): a reply that rewrites a document the chat already
// has (same kind, same title) is its next version; the panel steps between them.
test("a document's versions are the chat's documents of its kind and title, oldest first", async () => {
  const { artifactVersions } = await import("../src/agent-session/acpmux/conversation/artifactVersions");
  const replies = [
    "Here it is:\n\n```html\n<title>Pricing</title><p>One plan</p>\n```\n",
    "And notes:\n\n```md\n# Pricing\n\nNot HTML.\n```\n\n```html\n<title>Signup</title>\n```",
    "Updated, quoted:\n\n> ```html\n> <title>Pricing</title><p>Two plans</p>\n> ```\n",
    // The transcript draws a `~~~` fence as text, with no Open: not a version.
    "~~~html\n<title>Pricing</title><p>Draft</p>\n~~~",
  ];
  const opened = { kind: "html" as const, lang: "html", code: "<title>Pricing</title><p>Two plans</p>" };
  expect(artifactVersions(replies, opened).map((version) => version.code)).toEqual([
    "<title>Pricing</title><p>One plan</p>",
    "<title>Pricing</title><p>Two plans</p>",
  ]);
  // A document with no title, or one the chat has once, has only itself.
  const untitled = { kind: "svg" as const, lang: "svg", code: "<svg/>" };
  expect(artifactVersions(["```svg\n<svg/>\n```", "```svg\n<svg/>\n```"], untitled)).toEqual([untitled]);
  const signup = { kind: "html" as const, lang: "html", code: "<title>Signup</title>" };
  expect(artifactVersions(replies, signup)).toEqual([signup]);
});

test("a live artifact follows its fence identity and rejects an older row revision", async () => {
  const { artifactForIdentity, artifactIdentity } =
    await import("../src/agent-session/acpmux/conversation/artifactVersions");
  const identity = artifactIdentity("assistant-live", "0");
  const latest = artifactForIdentity(
    [
      {
        id: "assistant-live",
        version: 7,
        kind: "assistant",
        text: "```html\n<title>Pricing</title><p>Latest</p>\n```",
      },
    ],
    identity,
    6,
  );
  expect(latest).toMatchObject({
    identity,
    revision: 7,
    code: "<title>Pricing</title><p>Latest</p>",
  });
  expect(
    artifactForIdentity(
      [{ id: "assistant-live", version: 5, kind: "assistant", text: "```html\n<title>Pricing</title>\n```" }],
      identity,
      6,
    ),
  ).toBeUndefined();
});

test("the panel steps between a document's versions, starting on the one opened", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const version = (body: string) => ({ kind: "markdown" as const, lang: "md", code: `# Notes\n\n${body}` });
  const versions = [version("First."), version("Second."), version("Third.")];
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ArtifactPanel artifact={versions[1]!} versions={versions} onClose={() => {}} />));
  const count = () => host.querySelector(".acpmux-artifact-version")?.textContent;
  const body = () => host.querySelector(".acpmux-artifact-doc p")?.textContent;
  expect(count()).toBe("2/3");
  expect(body()).toBe("Second.");
  act(() => button("Next version")!.click());
  expect(count()).toBe("3/3");
  expect(body()).toBe("Third.");
  expect(button("Next version")!.disabled).toBe(true);
  act(() => button("Previous version")!.click());
  act(() => button("Previous version")!.click());
  expect(count()).toBe("1/3");
  expect(body()).toBe("First.");
  expect(button("Previous version")!.disabled).toBe(true);

  // The list moves under the panel (the reply it was opened from finished): it keeps the shown one.
  act(() =>
    root!.render(
      <ArtifactPanel artifact={versions[1]!} versions={[version("Zero."), ...versions]} onClose={() => {}} />,
    ),
  );
  expect(count()).toBe("2/4");
  expect(body()).toBe("First.");
  // A list without the shown one: only the opened one, no arrows.
  act(() => root!.render(<ArtifactPanel artifact={versions[1]!} versions={[versions[2]!]} onClose={() => {}} />));
  expect(body()).toBe("Second.");
  expect(button("Next version")).toBeUndefined();

  // One version: no arrows.
  act(() => root!.render(<ArtifactPanel artifact={versions[0]!} versions={[versions[0]!]} onClose={() => {}} />));
  expect(button("Next version")).toBeUndefined();
});

test("the open panel follows a newer live revision and ignores a stale one", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const version = (body: string, revision: number) => ({
    kind: "markdown" as const,
    lang: "md",
    code: `# Notes\n\n${body}`,
    identity: "assistant-live\u00000",
    revision,
  });
  const first = version("First.", 1);
  const second = version("Second.", 2);
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ArtifactPanel artifact={first} versions={[first]} onClose={() => {}} />));
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("First.");
  act(() => root!.render(<ArtifactPanel artifact={second} versions={[first, second]} onClose={() => {}} />));
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("Second.");
  act(() => root!.render(<ArtifactPanel artifact={first} versions={[first, second]} onClose={() => {}} />));
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("Second.");
});

test("a live source holds its highest revision through stale snapshots and prepends without scanning rows", async () => {
  const { ArtifactLiveSource } = await import("../src/agent-session/acpmux/conversation/artifactLive");
  const { artifactIdentity } = await import("../src/agent-session/acpmux/conversation/artifactVersions");
  const text = (body: string) => `\x60\x60\x60markdown\n# Notes\n\n${body}\n\x60\x60\x60`;
  const before = Array.from({ length: 2000 }, (_, index) => ({ id: `old-${index}`, version: 1, kind: "user" }));
  const live = { id: "live", version: 1, kind: "assistant", text: text("First.") };
  const source = new ArtifactLiveSource(
    {
      kind: "markdown",
      lang: "markdown",
      code: "# Notes\n\nFirst.",
      identity: artifactIdentity(live.id, "0"),
      revision: 1,
    },
    [...before, live],
  );
  let reads = 0;
  const snapshot = (version: number, body: string, prepend = false) =>
    new Proxy(
      [
        ...(prepend ? [{ id: "prepended", kind: "user", version: 1 }] : []),
        ...before,
        { ...live, version, text: text(body) },
      ],
      {
        get(target, key, receiver) {
          if (typeof key === "string" && /^\d+$/.test(key)) reads++;
          return Reflect.get(target, key, receiver);
        },
      },
    );
  expect(source.read(snapshot(7, "Newest.")).artifact.code).toContain("Newest.");
  expect(source.read(snapshot(6, "Stale.")).artifact.code).toContain("Newest.");
  expect(source.read(snapshot(8, "After page.", true)).artifact.code).toContain("After page.");
  expect(reads).toBeLessThan(12);
});

test("a selected historical version does not follow a live rewrite", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const old = { kind: "markdown" as const, lang: "md", code: "# Notes\n\nHistorical." };
  const live = { ...old, code: "# Notes\n\nCurrent.", identity: "live\u00000", revision: 1 };
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ArtifactPanel artifact={live} versions={[old, live]} onClose={() => {}} />));
  act(() => button("Previous version")!.click());
  const next = { ...live, code: "# Notes\n\nUpdated.", revision: 2 };
  act(() => root!.render(<ArtifactPanel artifact={next} versions={[old, next]} onClose={() => {}} />));
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("Historical.");
  // The bounded live history can evict it; the single explicitly chosen version stays held.
  act(() => root!.render(<ArtifactPanel artifact={next} versions={[next]} onClose={() => {}} />));
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("Historical.");
  act(() => button("Next version")!.click());
  expect(host.querySelector(".acpmux-artifact-doc p")?.textContent).toBe("Updated.");
});

test("an open plain fence carries its identity through the final code card", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const opened: unknown[] = [];
  act(() => root?.unmount());
  root = createRoot(host);
  const draw = (streaming: boolean, revision: number) =>
    act(() =>
      root!.render(
        <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
          <Markdown streaming={streaming} artifactIdentity="assistant-live" artifactRevision={revision} plainCode>
            {`\x60\x60\x60markdown\n# Notes\n\nLive.${streaming ? "" : "\n\x60\x60\x60"}`}
          </Markdown>
        </ArtifactContext.Provider>,
      ),
    );
  draw(true, 1);
  act(() => button("Open preview")!.click());
  draw(false, 2);
  act(() => button("Open preview")!.click());
  expect(opened).toEqual([
    expect.objectContaining({ identity: "assistant-live\u00000", revision: 1 }),
    expect.objectContaining({ identity: "assistant-live\u00000", revision: 2 }),
  ]);
});

test("Run follows one live artifact but passive markup cannot gain script consent", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const previousLocation = scope.location;
  scope.location = new URL("cmux-agent://pane/index.html");
  const version = (code: string, revision: number) => ({
    kind: "html" as const,
    lang: "html",
    code,
    identity: "live-run\u00000",
    revision,
  });
  const one = version("<script>/* first live revision */</script>", 1);
  const two = version("<script>/* second live revision */</script>", 2);
  try {
    act(() => root?.unmount());
    root = createRoot(host);
    const draw = (artifact: typeof one) =>
      act(() => root!.render(<ArtifactPanel artifact={artifact} versions={[artifact]} onClose={() => {}} />));
    draw(one);
    expect(button("Run")).toBeDefined();
    act(() => button("Run")!.click());
    const firstFrame = host.querySelector("iframe");
    draw(two);
    expect(button("Run")).toBeUndefined();
    expect(host.querySelector("iframe")).not.toBe(firstFrame);
    act(() => root!.unmount());
    root = createRoot(host);
    draw(version("<p>Passive markup</p>", 1));
    expect(host.querySelector("iframe")).not.toBeNull();
    draw(version("<script>/* newly introduced code */</script>", 2));
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
  } finally {
    act(() => root?.unmount());
    root = undefined;
    if (previousLocation === undefined) delete scope.location;
    else scope.location = previousLocation;
  }
});

test("the panel names the document, copies when saving fails, and hands focus back on close", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  const code = "# Release notes\n\nRetry now backs off.";
  const opener = window.document.createElement("button");
  window.document.body.append(opener);
  opener.focus();

  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactPanel
        artifact={{ kind: "markdown", lang: "markdown", code }}
        onClose={() => {}}
        onSave={() => Promise.reject(new Error("no host"))}
      />,
    ),
  );
  const title = host.querySelector<HTMLElement>(".acpmux-artifact-title")!;
  expect(title.textContent).toBe("Release notes");
  // Its name shows; no tooltip repeats it (test/tooltip-rules.ts).
  expect(title.title).toBe("");

  await act(async () => button("Save")!.click());
  expect(copied).toEqual([code]);

  // Focus moved into the panel (its Code tab), then the panel closes.
  button("Code")!.focus();
  act(() => root!.unmount());
  root = undefined;
  expect(window.document.activeElement).toBe(opener);
  opener.remove();
});

test("the unavailable highlighter keeps a fence's live source identity", async () => {
  const { createRoot } = await import("react-dom/client");
  const { HighlightedCode } = await import("../src/agent-session/acpmux/conversation/HighlightedCode");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const opened: unknown[] = [];
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
        <HighlightedCode lang="markdown" code="# Notes" artifactIdentity={"reply\u00000"} artifactRevision={4} />
      </ArtifactContext.Provider>,
    ),
  );
  act(() => button("Open preview")!.click());
  expect(opened).toEqual([expect.objectContaining({ identity: "reply\u00000", revision: 4 })]);
});

test("nested quoted and list fences keep recursive identities that resolve the matching source", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const { artifactForIdentity } = await import("../src/agent-session/acpmux/conversation/artifactVersions");
  const sources = [
    "> ```markdown\n> # Notes\n>\n> First\n> ```\n",
    "- Document\n\n  ```markdown\n  # Notes\n\n  First\n  ```\n",
  ];
  for (const text of sources) {
    const opened: { identity?: string }[] = [];
    act(() => root?.unmount());
    root = createRoot(host);
    act(() =>
      root!.render(
        <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
          <Markdown artifactIdentity="nested" artifactRevision={2} plainCode>
            {text}
          </Markdown>
        </ArtifactContext.Provider>,
      ),
    );
    act(() => button("Open preview")!.click());
    const identity = opened[0]?.identity;
    expect(identity).toBeDefined();
    expect(
      artifactForIdentity(
        [{ id: "nested", version: 3, kind: "assistant", text: text.replace("First", "Second") }],
        identity!,
      )?.code,
    ).toContain("Second");
  }
});
