// An option preview an agent wrote as HTML (Claude Code's AskUserQuestion with previewFormat
// "html", acpmux labels it `format: "html"`) draws as a picture in a frame that runs nothing and
// loads nothing, never as markup text and never in the pane's document. A monospace preview still
// draws as text in its box.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { previewDocument } from "./HtmlPreview";
import type { AgentQuestion } from "./model";
import { QuestionCard } from "./QuestionCard";

const fixture = (name: string): AgentQuestion =>
  JSON.parse(
    fs.readFileSync(
      fileURLToPath(
        new URL(
          `../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/${name}.json`,
          import.meta.url,
        ),
      ),
      "utf8",
    ),
  );

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "DOMParser",
  "ResizeObserver",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

class NoResize {
  observe() {}
  disconnect() {}
}

function installDom() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    DOMParser: dom.window.DOMParser,
    ResizeObserver: NoResize,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
}

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
});

async function render(question: AgentQuestion): Promise<HTMLElement> {
  installDom();
  const host = document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<QuestionCard question={question} onReply={() => undefined} />));
  return host;
}

test("an HTML preview draws in a frame that runs no script", async () => {
  const host = await render(fixture("pending-with-html-preview"));
  const section = host.querySelector(".acpmux-question-preview")!;
  expect(section.getAttribute("data-format")).toBe("html");
  // Never as markup text in a monospace box.
  expect(section.querySelector("pre")).toBeNull();
  const frame = section.querySelector("iframe")!;
  // No allow-scripts: nothing in the fragment runs. Same origin only so the card can measure it.
  expect(frame.getAttribute("sandbox")).toBe("allow-same-origin");
  const doc = frame.getAttribute("srcdoc")!;
  expect(doc).toContain("Deploy to staging?");
  expect(doc).toContain(`http-equiv="Content-Security-Policy"`);
  expect(doc).toContain("default-src 'none'");
});

test("a monospace preview still draws as text", async () => {
  const host = await render(fixture("pending-with-preview"));
  const section = host.querySelector(".acpmux-question-preview")!;
  expect(section.getAttribute("data-format")).toBe("monospace");
  expect(section.querySelector("iframe")).toBeNull();
  expect(section.querySelector("pre")?.textContent).toContain("General");
});

test("the frame's document drops what runs, loads or navigates", () => {
  installDom();
  const doc = previewDocument(
    [
      `<div onclick="alert(1)" style="color:red">Card</div>`,
      `<script>alert(2)</script>`,
      `<meta http-equiv="refresh" content="0;url=https://example.com">`,
      `<base href="https://example.com/">`,
      `<link rel="stylesheet" href="https://example.com/x.css">`,
      `<iframe src="https://example.com"></iframe>`,
      `<a href="javascript:alert(3)" target="_top">js</a>`,
      `<a href="https://example.com">away</a>`,
      `<a href="#here">here</a>`,
      `<img src="https://example.com/x.png"><img src="data:image/png;base64,AAAA">`,
      // A list whose first candidate is a data: image still names a remote one.
      `<img srcset="data:image/png;base64,BBBB 1x, https://example.com/2x.png 2x">`,
      `<svg><a xlink:href="https://example.com"><text>s</text></a></svg>`,
      // An SVG animation would set the link's href after the cleaning.
      `<svg><a href="#safe"><set attributeName="href" to="http://127.0.0.1:8080/x"/>`,
      `<animate attributeName="href" values="http://127.0.0.1:8080/y"/><text>t</text></a></svg>`,
    ].join(""),
    ":root{}",
  );
  const body = doc.slice(doc.indexOf("<body>"));
  expect(body).toContain(`style="color:red"`);
  expect(body).toContain("Card");
  for (const gone of [
    "onclick",
    "<script",
    "alert(2)",
    "<meta",
    "<base",
    "<link",
    "<iframe",
    "javascript:",
    "_top",
    "<set",
    "<animate",
    "127.0.0.1",
    "srcset",
  ])
    expect(body).not.toContain(gone);
  expect(body).not.toContain("example.com");
  expect(body).toContain(`href="#here"`);
  expect(body).toContain(`href="#safe"`);
  expect(body).toContain(`src="data:image/png;base64,AAAA"`);
  // The policy comes before the fragment, so it governs all of it.
  expect(doc.indexOf("Content-Security-Policy")).toBeLessThan(doc.indexOf("<body>"));
});
