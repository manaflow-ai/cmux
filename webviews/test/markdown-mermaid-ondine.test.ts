// Mermaid blocks in the markdown page render with Ondine (user 2026-10-19: "https://github.com/wevm/ondine
// should we use this? I think we might need a better Mermaid parser."; evaluation in
// plans/cmux-next/mermaid-ondine-EVAL.md). Ondine is the vendored Resources/markdown-viewer/ondine.min.js,
// a Rust-to-WebAssembly Mermaid compiler with no imports: source in, SVG text out. Mermaid 11 stays as
// the fallback for a source Ondine refuses, and as the renderer when the flag says "mermaid".
//
// Covered: every common diagram type draws through Ondine; script, handlers, javascript: links and
// HTML in labels never reach the page from either renderer; a refusal falls back to Mermaid; Mermaid
// output with HTML labels (`<br>`, unprefixed xlink) draws whole instead of an XML parse-error page.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { join } from "node:path";
import type * as Diagrams from "../src/pages/markdown/diagrams";

let diagrams: typeof Diagrams;
let dom: JSDOM;
const scope = globalThis as Record<string, unknown>;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "DOMParser", "Node", "Element", "HTMLElement", "SVGElement"]) {
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  // The host serves this file as `<libBase>ondine.js`; it sets `globalThis.ondine`.
  await import(join(import.meta.dir, "..", "..", "Resources", "markdown-viewer", "ondine.min.js"));
  diagrams = await import("../src/pages/markdown/diagrams");
});

afterEach(() => {
  delete scope.mermaid;
  document.body.replaceChildren();
});

/** Libraries whose scripts the test already loaded (no host): only present globals load. */
const libraries = () => new diagrams.DiagramLibraries(() => null);

const target = () => {
  const element = document.createElement("div");
  document.body.append(element);
  return element;
};

/** A stand-in Mermaid that records calls and returns `svg`, or throws `error`. */
function stubMermaid(svg: string, error?: Error) {
  const calls: string[] = [];
  scope.mermaid = {
    initialize() {},
    async render(_id: string, source: string) {
      calls.push(source);
      if (error) throw error;
      return { svg };
    },
  };
  return calls;
}

/** Everything that could run script or leave the page from a drawn diagram. */
function hazards(root: Element): string[] {
  const found: string[] = [];
  for (const element of [root, ...root.querySelectorAll("*")]) {
    const name = element.localName.toLowerCase();
    if (["script", "iframe", "object", "embed", "foreignobject"].includes(name)) found.push(`<${name}>`);
    for (const attribute of element.attributes) {
      const attr = attribute.name.toLowerCase();
      if (attr.startsWith("on")) found.push(`${name}[${attr}]`);
      const value = Array.from(attribute.value)
        .filter((char) => char.charCodeAt(0) > 32)
        .join("")
        .toLowerCase();
      if ((attr === "href" || attr.endsWith(":href") || attr === "src") && /^(javascript|data|vbscript):/.test(value)) {
        found.push(`${name}[${attr}=${attribute.value}]`);
      }
    }
  }
  return found;
}

const corpus: [type: string, source: string, labels: string[]][] = [
  [
    "flowchart",
    'flowchart TD\n  A["Unicode ✓ 日本語"] --> B{"Is it?"}\n  B -->|Yes| C[(Database)]\n  B -->|No| D((Circle))',
    ["Unicode ✓ 日本語", "Is it?", "Yes", "Database", "Circle"],
  ],
  ["flowchart", "flowchart LR\n  subgraph one\n    a1-->a2\n  end\n  one --> b", ["one", "a1", "a2", "b"]],
  [
    "sequence",
    "sequenceDiagram\n  autonumber\n  Alice->>+John: Hello\n  John-->>-Alice: Hi\n  loop Every minute\n    John->>Alice: ping\n  end",
    ["Alice", "John", "Hello", "Hi", "Every minute", "ping"],
  ],
  [
    "class",
    "classDiagram\n  class Animal {\n    +String name\n    +move(int dist) bool\n  }\n  Animal <|-- Dog",
    ["Animal", "+String name", "Dog"],
  ],
  [
    "state",
    "stateDiagram-v2\n  [*] --> Still\n  Still --> Moving\n  state Moving {\n    [*] --> Fast\n  }",
    ["Still", "Moving", "Fast"],
  ],
  ["er", "erDiagram\n  CUSTOMER ||--o{ ORDER : places", ["CUSTOMER", "ORDER", "places"]],
  [
    "gantt",
    "gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section A\n  Task1 :a1, 2026-01-01, 30d\n  Task2 :after a1, 20d",
    ["Plan", "Task1", "Task2"],
  ],
  ["pie", 'pie\n  title Pets\n  "Dogs" : 386\n  "Cats" : 85', ["Pets", "Dogs", "Cats"]],
  ["mindmap", "mindmap\n  root((cmux))\n    Terminal\n    Browser", ["cmux", "Terminal", "Browser"]],
  [
    "gitGraph",
    "gitGraph\n  commit\n  branch develop\n  checkout develop\n  commit\n  checkout main\n  merge develop",
    ["main", "develop"],
  ],
];

describe("Ondine renders mermaid blocks", () => {
  test.each(corpus)("%s draws through Ondine with every label", async (type, source, labels) => {
    const calls = stubMermaid("<svg></svg>");
    const element = target();
    await diagrams.renderMermaid(libraries(), source, element);
    const svg = element.firstElementChild;
    expect(svg?.localName).toBe("svg");
    expect(svg?.getAttribute("class") ?? "").toContain("ondine");
    expect(calls).toEqual([]);
    const text = svg?.textContent ?? "";
    for (const label of labels) expect(text).toContain(label);
    expect(hazards(element)).toEqual([]);
    void type;
  });

  test("Ondine follows the page colors", async () => {
    const element = target();
    await diagrams.renderMermaid(libraries(), "flowchart LR\n  A --> B", element);
    expect(element.firstElementChild?.getAttribute("style") ?? "").toContain("var(--ondine-fg");
  });
});

const payloads = [
  'flowchart TD\n  A["<img src=x onerror=alert(1)>"] --> B',
  'flowchart TD\n  A["<script>alert(1)</script>"]',
  'flowchart TD\n  A["<svg onload=alert(1)>"]',
  "flowchart TD\n  A[\"<a href='javascript:alert(1)'>x</a>\"]",
  'flowchart TD\n  A[x]\n  click A "javascript:alert(1)"',
  'flowchart TD\n  A[x]\n  click A href "  JaVaScRiPt:alert(1)"',
  'flowchart TD\n  A[x]\n  click A "data:text/html,<script>alert(1)</script>"',
  'flowchart TD\n  A[x]\n  click A "&#106;avascript:alert(1)"',
  '%%{init: {"securityLevel":"loose"}}%%\nflowchart TD\n  A[x]\n  click A "javascript:alert(1)"',
  "sequenceDiagram\n  A->>B: <img src=x onerror=alert(1)>",
  "sequenceDiagram\n  participant A as <script>alert(1)</script>",
  'classDiagram\n  class A\n  click A href "javascript:alert(1)"',
  "stateDiagram-v2\n  A: <img src=x onerror=alert(1)>",
  'pie\n  "<img src=x onerror=alert(1)>" : 1',
  'mindmap\n  root["<img src=x onerror=alert(1)>"]',
  'gitGraph\n  commit id: "<img src=x onerror=alert(1)>"',
  "flowchart TD\n  A[\"</text><foreignObject><div xmlns='http://www.w3.org/1999/xhtml'><img src=x onerror=alert(1)></div></foreignObject><text>\"]",
];

describe("no script reaches the page", () => {
  test.each(payloads)("Ondine output of %p is inert", async (source) => {
    stubMermaid("<svg></svg>", new Error("mermaid refused"));
    const element = target();
    await diagrams.renderMermaid(libraries(), source, element).catch(() => {});
    expect(hazards(element)).toEqual([]);
  });

  test("hostile Mermaid output is cleaned before it is shown", async () => {
    stubMermaid(
      '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><script>alert(2)</script>' +
        '<a href="javascript:alert(3)"><text>go</text></a><a xlink:href=" javascript:alert(4)"><text>x</text></a>' +
        '<foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><img src="x" onerror="alert(5)">label</div></foreignObject>' +
        '<image href="data:image/svg+xml,&lt;svg onload=alert(6)&gt;"/><g onclick="alert(7)"><text>ok</text></g></svg>',
    );
    const element = target();
    await diagrams.renderMermaid(libraries(), "flowchart TD\n  A -- broken ->", element, "mermaid");
    expect(hazards(element).filter((hazard) => hazard !== "<foreignobject>")).toEqual([]);
    expect(element.textContent).toContain("label");
    expect(element.textContent).toContain("ok");
  });
});

describe("fallback and flag", () => {
  test("a source Ondine refuses falls back to Mermaid", async () => {
    const calls = stubMermaid('<svg xmlns="http://www.w3.org/2000/svg"><text>from mermaid</text></svg>');
    const element = target();
    const source = "architecture-beta\n  service s(<img src=x onerror=alert(1)>)[x]";
    await diagrams.renderMermaid(libraries(), source, element);
    expect(calls).toEqual([source]);
    expect(element.textContent).toContain("from mermaid");
  });

  test("when both refuse, Ondine's reason is reported", async () => {
    stubMermaid("", new Error("mermaid says no"));
    await expect(diagrams.renderMermaid(libraries(), "flowchart TD\n  A --> ", target())).rejects.toThrow(
      /Parse error/,
    );
  });

  test('the "mermaid" flag uses Mermaid even for a source Ondine draws', async () => {
    const calls = stubMermaid('<svg xmlns="http://www.w3.org/2000/svg"><text>from mermaid</text></svg>');
    const element = target();
    await diagrams.renderMermaid(libraries(), "flowchart LR\n  A --> B", element, "mermaid");
    expect(calls.length).toBe(1);
    expect(element.textContent).toContain("from mermaid");
  });

  test("Mermaid output with HTML labels draws whole, not as an XML error page", async () => {
    // Mermaid 11 writes labels as HTML in <foreignObject> (`<br>` unclosed) and `xlink:href`
    // without declaring the prefix; parsed as XML that stops at the first error.
    stubMermaid(
      '<svg xmlns="http://www.w3.org/2000/svg"><g><foreignObject><div xmlns="http://www.w3.org/1999/xhtml">' +
        '<span>line one<br>line two</span></div></foreignObject><a xlink:href="https://example.com"><text>after</text></a></g></svg>',
    );
    const element = target();
    await diagrams.renderMermaid(libraries(), "flowchart TD\n  A --> B", element, "mermaid");
    expect(element.querySelector("parsererror")).toBeNull();
    expect(element.textContent).toContain("line two");
    expect(element.textContent).toContain("after");
  });
});
