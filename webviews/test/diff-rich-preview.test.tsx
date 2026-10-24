// Inline previews: an image file always shows its two sides in place of its diff, and with Rich
// preview on a Markdown file shows its new version rendered. Markdown renders from marked's tokens
// as React elements (raw HTML stays text), an image shows from `data:` URLs, and both sides come
// through one loader (the host's `fileContents`), asked once per file per session.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
  KeyboardEvent: dom.window.KeyboardEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { loadDiffViewerLabels, createDiffViewerLabelResolver } = await import("../src/labels");
await loadDiffViewerLabels("en");
const { previewKindOf, previewEncodingOf, imageDataURL, markdownText } = await import("../src/diff-viewer/richPreview");
const { MarkdownPreview } = await import("../src/diff-viewer/MarkdownPreview");
const { InlinePreview, isPreviewAnnotation, previewItemFor } = await import("../src/diff-viewer/InlinePreview");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const document = dom.window.document;
const settle = () => act(async () => {});

async function render(element: React.ReactElement) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(element));
  await settle();
  return {
    container,
    unmount: async () => {
      await act(async () => root.unmount());
      container.remove();
    },
  };
}

test("Markdown and image files preview; others do not", () => {
  expect(previewKindOf("docs/guide.md")).toBe("markdown");
  expect(previewKindOf("README.markdown")).toBe("markdown");
  expect(previewKindOf("logo.PNG")).toBe("image");
  expect(previewKindOf("art/icon.svg")).toBe("image");
  expect(previewKindOf("src/app.ts")).toBeUndefined();
  expect(previewKindOf("Makefile")).toBeUndefined();
  expect(previewEncodingOf("image")).toBe("base64");
  expect(previewEncodingOf("markdown")).toBe("text");
});

test("a side becomes a data URL or text, whatever encoding the host sent", () => {
  expect(imageDataURL("a.png", { contents: "iVBORw0KGgo=", encoding: "base64" })).toBe(
    "data:image/png;base64,iVBORw0KGgo=",
  );
  expect(imageDataURL("a.svg", { contents: "<svg/>", encoding: "text" })).toBe(
    `data:image/svg+xml;base64,${btoa("<svg/>")}`,
  );
  expect(imageDataURL("a.png", undefined)).toBeUndefined();
  expect(markdownText({ contents: btoa("# Hi"), encoding: "base64" })).toBe("# Hi");
  expect(markdownText({ contents: "# Hi", encoding: "text" })).toBe("# Hi");
});

test("Markdown renders as elements, and raw HTML stays text", async () => {
  const source = [
    "# Guide",
    "",
    "Some **bold** and `code` and [a link](https://example.com).",
    "",
    "- [x] done",
    "- [ ] open",
    "",
    "| a | b |",
    "|---|---|",
    "| 1 | 2 |",
    "",
    '<script>window.ran = true</script><img src="https://example.com/x.png">',
    "",
    "![alt text](https://example.com/y.png)",
  ].join("\n");
  const view = await render(<MarkdownPreview source={source} />);
  const root = view.container;
  expect(root.querySelector("h1")?.textContent).toBe("Guide");
  expect(root.querySelector("strong")?.textContent).toBe("bold");
  expect(root.querySelector("code")?.textContent).toBe("code");
  expect(root.querySelector(".md-link")?.textContent).toBe("a link");
  expect([...root.querySelectorAll("li")].map((li) => li.getAttribute("data-task"))).toEqual(["done", "open"]);
  expect(root.querySelectorAll("td").length).toBe(2);
  // Nothing from the file becomes a live element: no script, no image, no anchor.
  expect(root.querySelector("script, img, a, iframe")).toBeNull();
  expect(root.textContent).toContain("<script>");
  expect(root.querySelector(".md-image")?.textContent).toBe("alt text");
  expect((dom.window as unknown as { ran?: boolean }).ran).toBeUndefined();
  await view.unmount();
});

const item = (name: string, extra: Record<string, unknown> = {}) =>
  ({ id: `id-${name}`, fileDiff: { name, hunks: [], ...extra } }) as never;

test("images always preview, Markdown and SVG only with Rich preview on, and only where the host can read", () => {
  const image = previewItemFor(item("logo.png"), { richPreview: false, canRead: true });
  expect(image?.type).toBe("file");
  expect(image?.id).toBe("id-logo.png");
  expect(image?.annotations[0]?.metadata).toEqual({ kind: "rich-preview", preview: "image", path: "logo.png" });
  expect(isPreviewAnnotation(image?.annotations[0])).toBe(true);
  expect(previewItemFor(item("docs/guide.md"), { richPreview: false, canRead: true })).toBeNull();
  expect(
    previewItemFor(item("docs/guide.md"), { richPreview: true, canRead: true })?.annotations[0]?.metadata.preview,
  ).toBe("markdown");
  expect(previewItemFor(item("src/app.ts"), { richPreview: true, canRead: true })).toBeNull();
  expect(previewItemFor(item("logo.png"), { richPreview: true, canRead: false })).toBeNull();
  // An SVG is text: its diff (and hunk Stage and Revert) stays unless Rich preview is on.
  expect(previewItemFor(item("art/icon.svg"), { richPreview: false, canRead: true })).toBeNull();
  expect(
    previewItemFor(item("art/icon.svg"), { richPreview: true, canRead: true })?.annotations[0]?.metadata.preview,
  ).toBe("image");
  // A rename names its old path, so the old side reads from there.
  const renamed = previewItemFor(item("art/new.png", { prevName: "art/old.png" }), {
    richPreview: false,
    canRead: true,
  });
  expect(renamed?.annotations[0]?.metadata.previousPath).toBe("art/old.png");
});

const annotationOf = (path: string, preview: "markdown" | "image") =>
  ({ lineNumber: 1, metadata: { kind: "rich-preview", preview, path } }) as const;

test("Markdown shows only its new version, rendered", async () => {
  const load = async () => ({
    old: { contents: "# Old title", encoding: "text" as const },
    new: { contents: "# New title", encoding: "text" as const },
  });
  const view = await render(
    <InlinePreview
      annotation={annotationOf("docs/guide.md", "markdown")}
      load={load}
      cache={new Map()}
      label={label}
    />,
  );
  expect(view.container.querySelector(".inline-preview h1")?.textContent).toBe("New title");
  expect(view.container.textContent).not.toContain("Old title");
  await view.unmount();
});

test("an image shows both sides with no captions; an added one says it has no old side", async () => {
  const load = async () => ({ new: { contents: "iVBORw0KGgo=", encoding: "base64" as const } });
  const view = await render(
    <InlinePreview annotation={annotationOf("logo.png", "image")} load={load} cache={new Map()} label={label} />,
  );
  const figures = [...view.container.querySelectorAll(".rich-preview-image")];
  // No captions: the old side is first, the new second; the alt text says which.
  expect(figures.map((figure) => figure.getAttribute("data-side"))).toEqual(["old", "new"]);
  expect(view.container.querySelector("figcaption")).toBeNull();
  expect(figures[0]!.querySelector("img")).toBeNull();
  expect(figures[0]!.textContent).toContain("No file");
  expect(figures[1]!.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,iVBORw0KGgo=");
  expect(figures[1]!.querySelector("img")?.getAttribute("alt")).toBe("After: logo.png");
  await view.unmount();
});

test("a preview scrolled away and back asks the host once per session", async () => {
  let reads = 0;
  const load = async () => {
    reads += 1;
    return { new: { contents: "# Hi", encoding: "text" as const } };
  };
  const cache = new Map();
  const first = await render(
    <InlinePreview annotation={annotationOf("a.md", "markdown")} load={load} cache={cache} label={label} />,
  );
  await first.unmount();
  const again = await render(
    <InlinePreview annotation={annotationOf("a.md", "markdown")} load={load} cache={cache} label={label} />,
  );
  expect(again.container.querySelector("h1")?.textContent).toBe("Hi");
  expect(reads).toBe(1);
  await again.unmount();
});

test("too large and failed reads say so", async () => {
  const large = await render(
    <InlinePreview
      annotation={annotationOf("a.md", "markdown")}
      load={async () => ({ tooLarge: true })}
      cache={new Map()}
      label={label}
    />,
  );
  expect(large.container.textContent).toBe("This file is too large to preview.");
  await large.unmount();
  const failed = await render(
    <InlinePreview
      annotation={annotationOf("a.md", "markdown")}
      load={async () => Promise.reject(new Error("no"))}
      cache={new Map()}
      label={label}
    />,
  );
  expect(failed.container.textContent).toBe("Could not load this file.");
  await failed.unmount();
});
