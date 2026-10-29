// l10n-allow-file: test fixture app names, not shipped UI.
// The source app's icon at an attachment's top-right corner (SourceBadge.tsx): the host's own PNG
// for a known app, nothing for an unknown source or an answer that is not one.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AttachmentSource } from "../attachments";
import { resetSourceIcons, SourceBadge, withSourceLabel } from "./SourceBadge";

const PNG = "data:image/png;base64,iVBORw0KGgo=";
const chrome: AttachmentSource = { name: "Google Chrome", bundleId: "com.google.Chrome", site: "github.com" };

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  resetSourceIcons();
});

/// Renders `node` with the host answering `attachment.sourceIcon` by `answer`; returns the
/// container and the bundle ids asked for.
async function render(node: ReactNode, answer: (bundleId: string) => unknown) {
  dom?.window.close();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  const asked: string[] = [];
  Object.assign(dom.window, {
    cmuxAcpmuxActions: {
      "attachment.sourceIcon": async (params: Record<string, unknown>) => {
        asked.push(String(params.bundleId));
        return answer(String(params.bundleId));
      },
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  // The host's answer lands a tick later.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { container, asked };
}

test("a known app's icon sits on the tile, named for screen readers", async () => {
  const { container, asked } = await render(
    <>
      <SourceBadge source={chrome} />
      <SourceBadge source={chrome} />
    </>,
    () => ({ src: PNG }),
  );
  const badges = container.querySelectorAll(".acpmux-source-badge");
  expect(badges.length).toBe(2);
  expect(badges[0]!.getAttribute("aria-label")).toBe("From Google Chrome · github.com");
  expect(badges[0]!.querySelector("img")!.getAttribute("src")).toBe(PNG);
  // One ask per app, however many tiles wear it.
  expect(asked).toEqual(["com.google.Chrome"]);
});

test("no icon for an unknown source, an app with no id, or an answer that is not a PNG", async () => {
  for (const [source, answer] of [
    [undefined, { src: PNG }],
    [{ name: "Screenshot" }, { src: PNG }],
    [chrome, { src: "data:image/svg+xml;base64,PHN2Zy8+" }],
    [chrome, { src: "https://example.com/icon.png" }],
    [chrome, {}],
  ] as const) {
    const { container } = await render(<SourceBadge source={source} />, () => answer);
    expect(container.innerHTML).toBe("");
    await act(async () => root!.unmount());
    root = undefined;
    resetSourceIcons();
  }
});

test("a host that refuses the ask shows none", async () => {
  const { container } = await render(<SourceBadge source={chrome} />, () => {
    throw new Error("unsupported");
  });
  expect(container.innerHTML).toBe("");
});

test("the tooltip puts the source under the tile's own title", () => {
  expect(withSourceLabel("image.png", "From Finder")).toBe("image.png\nFrom Finder");
  expect(withSourceLabel(undefined, "From Finder")).toBe("From Finder");
  expect(withSourceLabel("image.png", undefined)).toBe("image.png");
});
