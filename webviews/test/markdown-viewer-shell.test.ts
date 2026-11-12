import { afterEach, describe, expect, test } from "bun:test";
import type { JSDOM } from "jsdom";
import { loadShell, unsafeNodes } from "./markdown-viewer-shell.harness";

let active: JSDOM | null = null;

afterEach(() => {
  active?.window.close();
  active = null;
});

function shell() {
  const loaded = loadShell();
  active = loaded.dom;
  return loaded;
}

async function flush() {
  for (let i = 0; i < 5; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

describe("markdown viewer renders untrusted markdown without active content", () => {
  const payloads: Array<[string, string]> = [
    ["comment and noscript mutation", '<!--x--><noscript><p title="</noscript><img src=x onerror=alert(1)>">'],
    ["noembed", '<noembed><p title="</noembed><img src=x onerror=alert(1)>">'],
    ["noframes", '<noframes><p title="</noframes><img src=x onerror=alert(1)>">'],
    ["xmp", '<xmp><p title="</xmp><img src=x onerror=alert(1)>">'],
    ["plaintext", "<plaintext><img src=x onerror=alert(1)>"],
    ["inert and plugin containers", "<template><img src=x onerror=alert(1)></template><iframe srcdoc='<script>alert(1)</script>'></iframe><object data=x></object><embed src=x><style>*{}</style><script>alert(1)</script>"],
    ["SVG animation", '<svg><a href="#"><animate attributeName="href" to="javascript:alert(1)"/><set attributeName="href" to="javascript:alert(1)"/><text>x</text></a></svg>'],
    ["MathML", "<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>"],
    ["event attributes", "<div onclick=alert(1) onmouseover=alert(1)>x</div><details open ontoggle=alert(1)>y</details>"],
    ["javascript links", '[x](javascript:alert(1)) <a href="JaVaScRiPt:alert(1)">y</a> <a href="jav&#x09;ascript:alert(1)">z</a> <a href="vbscript:x">v</a>'],
    ["data URL navigation", '<a href="data:text/html,<script>alert(1)</script>">x</a>'],
    ["form controls", '<form action="https://x"><button formaction="javascript:alert(1)">b</button><input type=text autofocus onfocus=alert(1)></form>'],
    ["host-owned attributes", '<img data-cmux-remote-src="https%3A%2F%2Fexample.com%2Fa.png" src="x.png"><span class="cmux-remote-image-placeholder">fake</span>'],
  ];

  for (const [name, payload] of payloads) {
    test(name, () => {
      const { render } = shell();
      const content = render(payload);
      expect(unsafeNodes(content)).toEqual([]);
      expect(
        content.querySelector("svg, math, form, button, iframe, object, embed, noscript, template, [data-cmux-remote-src]"),
      ).toBeNull();
      expect(content.querySelector(".cmux-remote-image-placeholder")).toBeNull();
    });
  }

  test("inline SVG renders as an inert image", () => {
    const { render } = shell();
    const content = render(
      '<svg width="40" height="20" xmlns="http://www.w3.org/2000/svg"><rect width="40" height="20" fill="teal"/><script>alert(1)</script><a href="#"><animate attributeName="href" to="javascript:alert(1)"/><text>x</text></a></svg>\n\nafter',
    );
    expect(unsafeNodes(content)).toEqual([]);
    expect(content.querySelector("svg, script, animate, a")).toBeNull();
    const img = content.querySelector("img.cmux-inline-svg");
    expect(img).not.toBeNull();
    const src = img?.getAttribute("src") ?? "";
    expect(src.startsWith("data:image/svg+xml;base64,")).toBe(true);
    const xml = Buffer.from(src.slice("data:image/svg+xml;base64,".length), "base64").toString("utf8");
    expect(xml).toContain('<rect width="40" height="20" fill="teal"');
    expect(content.textContent).toContain("after");
  });

  test("frontmatter is routed through the sanitizer", () => {
    const { dom, render } = shell();
    const hljs = (dom.window as unknown as { hljs: { highlight: (...args: unknown[]) => { value: string } } }).hljs;
    hljs.highlight = () => ({ value: '<img src=x onerror=alert(1)><!--c--><noscript>n</noscript><span class="hljs-attr">title</span>' });
    const content = render("---\ntitle: <img src=x onerror=alert(1)>\n---\n# Doc");
    expect(unsafeNodes(content)).toEqual([]);
    expect(content.querySelector(".cmux-frontmatter .hljs-attr")?.textContent).toBe("title");
    expect(content.querySelector("h1")?.textContent).toBe("Doc");
  });

  test("ordinary markdown keeps its structure", () => {
    const { render } = shell();
    const content = render(
      [
        "# Title",
        "",
        "<p align=\"center\"><b>bold</b></p>",
        "",
        "- [x] done",
        "",
        "| a | b |",
        "|---|---|",
        "| 1 | 2 |",
        "",
        "[docs](https://example.com) [anchor](#title) ![local](images/a.png)",
        "",
        "```ts",
        "const a = 1 < 2;",
        "```",
      ].join("\n"),
    );
    expect(content.querySelector("h1#title")?.textContent).toBe("Title");
    expect(content.querySelector("p[align=center] b")?.textContent).toBe("bold");
    expect(content.querySelector("input[type=checkbox][disabled]")).not.toBeNull();
    expect(content.querySelectorAll("table td").length).toBe(2);
    expect(content.querySelector("a[href='https://example.com']")?.getAttribute("rel")).toBe("noopener noreferrer");
    expect(content.querySelector("a[href='#title']")).not.toBeNull();
    expect(content.querySelector("img")?.getAttribute("src")).toStartWith("cmux-local-image://image?url=");
    expect(content.querySelector("pre code.hljs")?.textContent).toContain("const a = 1 < 2;");
    expect(content.querySelector("pre code.hljs .hljs-keyword")?.textContent).toBe("const");
  });
});

describe("generated diagrams are sanitized", () => {
  const hostileSVG = [
    '<svg id="m" viewBox="0 0 10 10" style="max-width: 100px;">',
    '<style>#m .node{fill:red}</style>',
    '<style>@import url(https://attacker.example/x.css);</style>',
    '<a href="javascript:alert(1)"><text>link</text></a>',
    '<g onclick="alert(1)"><animate attributeName="href" to="javascript:alert(1)"/>',
    '<rect width="10" height="10" fill="url(#grad)" style="fill:url(https://attacker.example/x)"/></g>',
    '<image href="https://attacker.example/x.png"/>',
    '<use href="https://attacker.example/sprite.svg#a"/>',
    '<foreignObject><div class="nodeLabel" style="display: table-cell;"><img src=x onerror=alert(1)>label</div></foreignObject>',
    "<script>alert(1)</script>",
    '<path d="M0 0L10 10" marker-end="url(#arrow)"/>',
    "</svg>",
  ].join("");

  test("Mermaid output", async () => {
    const { dom, posted, render } = shell();
    const win = dom.window as unknown as Record<string, unknown> & { __cmuxLibLoaded(name: string): void };
    win.mermaid = {
      initialize() {},
      render: async () => ({ svg: hostileSVG, bindFunctions: () => { throw new Error("bindings must not be attached"); } }),
    };
    const content = render("```mermaid\ngraph TD; A-->B\n```");
    expect(posted).toContainEqual({ lib: "mermaid" });
    win.__cmuxLibLoaded("mermaid");
    await flush();
    const svg = content.querySelector(".cmux-mermaid svg");
    expect(svg).not.toBeNull();
    const findings = unsafeNodes(content).filter((finding) => finding !== "element:style" && finding !== "element:foreignobject");
    expect(findings).toEqual([]);
    expect(content.querySelector(".cmux-mermaid a, .cmux-mermaid image, .cmux-mermaid script, .cmux-mermaid img, .cmux-mermaid animate")).toBeNull();
    expect(content.querySelector(".cmux-mermaid use")?.hasAttribute("href")).toBe(false);
    expect(content.querySelector(".cmux-mermaid rect")?.getAttribute("fill")).toBe("url(#grad)");
    expect(content.querySelector(".cmux-mermaid rect")?.hasAttribute("style")).toBe(false);
    expect(content.querySelector(".cmux-mermaid path")?.getAttribute("marker-end")).toBe("url(#arrow)");
    const styles = Array.from(content.querySelectorAll(".cmux-mermaid style")).map((style) => style.textContent);
    expect(styles).toEqual(["#m .node{fill:red}", ""]);
    expect(content.querySelector(".cmux-mermaid foreignObject div.nodeLabel")?.textContent).toBe("label");
  });

  test("Vega output", async () => {
    const { dom, render } = shell();
    const win = dom.window as unknown as Record<string, unknown> & { __cmuxLibLoaded(name: string): void };
    let finalized = false;
    let embedTarget: unknown = null;
    win.vegaEmbed = async (target: unknown) => {
      embedTarget = target;
      return { view: { toSVG: async () => hostileSVG }, finalize: () => { finalized = true; } };
    };
    const content = render('```vega-lite\n{"mark": "bar", "data": {"values": [{"a": 1}]}}\n```');
    const block = content.querySelector(".cmux-vega");
    win.__cmuxLibLoaded("vega-lite");
    await flush();
    expect(embedTarget).not.toBe(block);
    expect(finalized).toBe(true);
    const findings = unsafeNodes(content).filter((finding) => finding !== "element:style" && finding !== "element:foreignobject");
    expect(findings).toEqual([]);
    expect(content.querySelector(".cmux-vega svg")).not.toBeNull();
    expect(content.querySelector(".cmux-vega a, .cmux-vega image, .cmux-vega script, .cmux-vega img")).toBeNull();
  });
});

describe("remote images", () => {
  test("loading requires the host approval callback and opening goes through the host", () => {
    const { dom, posted, render } = shell();
    const opened: unknown[] = [];
    (dom.window as unknown as { open: (...args: unknown[]) => void }).open = (...args: unknown[]) => { opened.push(args); };
    const content = render("![x](https://example.com/a.png)");
    const img = content.querySelector("img[data-cmux-remote-src]") as HTMLImageElement;
    expect(img.hasAttribute("src")).toBe(false);
    const buttons = Array.from(content.querySelectorAll(".cmux-remote-image-placeholder button")) as HTMLButtonElement[];
    const load = buttons.find((button) => button.getAttribute("data-cmux-remote-action") === "load") as HTMLButtonElement;
    const open = buttons[buttons.length - 1];

    load.click();
    expect(posted).toContainEqual({ action: "approveRemoteImage", url: "https://example.com/a.png" });
    expect(img.hasAttribute("src")).toBe(false);

    const win = dom.window as unknown as { __cmuxRemoteImageApproved(href: string): void; __cmuxRemoteImageRejected(href: string): void };
    win.__cmuxRemoteImageApproved("https://example.com/a.png");
    expect(img.getAttribute("src")).toBe(`cmux-remote-image://image?url=${encodeURIComponent("https://example.com/a.png")}`);

    open.click();
    expect(posted).toContainEqual({ action: "openRemoteImage", url: "https://example.com/a.png" });
    expect(opened).toEqual([]);
  });

  test("a rejected approval resets the placeholder", () => {
    const { dom, render } = shell();
    const content = render("![x](https://example.com/a.png)");
    const load = content.querySelector("button[data-cmux-remote-action=load]") as HTMLButtonElement;
    load.click();
    expect(load.disabled).toBe(true);
    (dom.window as unknown as { __cmuxRemoteImageRejected(href: string): void }).__cmuxRemoteImageRejected("https://example.com/a.png");
    expect(load.disabled).toBe(false);
    expect(content.querySelector("img")?.hasAttribute("src")).toBe(false);
  });
});
