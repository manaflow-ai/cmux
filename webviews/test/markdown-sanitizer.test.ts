import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import "../../Resources/markdown-viewer/markdown-sanitizer.js";
import { unsafeNodes } from "./markdown-viewer-shell.harness";

const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
const doc = dom.window.document;

afterAll(() => {
  dom.window.close();
});

function sanitize(
  html: string,
  profile = CmuxMarkdownSanitizer.markdownProfile({ url: ({ value }) => value }),
): HTMLElement {
  const root = doc.getElementById("root") as HTMLElement;
  root.replaceChildren(CmuxMarkdownSanitizer.sanitizeToFragment(html, { document: doc, profile }));
  return root;
}

describe("shared markdown sanitizer", () => {
  test("drops comments and whole subtrees of unlisted elements", () => {
    const root = sanitize("<p>a<!--c-->b</p><noscript><b>hidden</b></noscript><custom-el><b>x</b></custom-el>");
    expect(root.innerHTML).toBe("<p>ab</p>");
  });

  test("profiles cannot allow raw-text, scripting-dependent, or inert elements", () => {
    const profile = CmuxMarkdownSanitizer.markdownProfile({
      extraAttributes: {},
      url: () => null,
    });
    const root = sanitize(
      "<noscript>a</noscript><noembed>b</noembed><noframes>c</noframes><xmp>d</xmp><template>e</template><style>f</style><textarea>g</textarea><title>h</title><iframe></iframe><plaintext>i",
      profile,
    );
    expect(root.innerHTML).toBe("");
  });

  test("never copies event handlers or host-owned attributes", () => {
    const root = sanitize(
      '<p onclick="x" data-cmux-file="y" title="t" style="color:red" class="hljs-keyword cmux-remote-image-placeholder evil">x</p>',
    );
    expect(root.innerHTML).toBe('<p title="t" class="hljs-keyword">x</p>');
  });

  test("markdown profile drops all SVG and MathML", () => {
    const root = sanitize(
      '<svg><a href="#"><animate attributeName="href" to="javascript:alert(1)"/></a></svg><math><mi>x</mi></math>',
    );
    expect(root.innerHTML).toBe("");
  });

  test("diagram profile keeps static SVG and drops animation, links, images, and remote references", () => {
    const root = sanitize(
      '<svg viewBox="0 0 1 1"><defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs>' +
        '<a href="javascript:alert(1)"><text>t</text></a><set attributeName="fill" to="red"/>' +
        '<animateTransform attributeName="transform"/><image href="https://x/y.png"/>' +
        '<use href="#g"/><use xlink:href="https://x/s.svg#a"/><rect fill="url(#g)" stroke="url(https://x/y)"/></svg>',
      CmuxMarkdownSanitizer.diagramProfile(),
    );
    expect(unsafeNodes(root)).toEqual([]);
    expect(root.querySelector("a, set, animateTransform, image")).toBeNull();
    const uses = root.querySelectorAll("use");
    expect(uses[0].getAttribute("href")).toBe("#g");
    expect(uses[1].attributes.length).toBe(0);
    expect(root.querySelector("rect")?.getAttribute("fill")).toBe("url(#g)");
    expect(root.querySelector("rect")?.hasAttribute("stroke")).toBe(false);
    expect(root.querySelector("svg")?.getAttribute("viewBox")).toBe("0 0 1 1");
    expect(root.querySelector("linearGradient")).not.toBeNull();
  });

  test("CSS that can fetch, import, or execute is rejected", () => {
    expect(CmuxMarkdownSanitizer.sanitizeCSS("fill: red; stroke: url(#a)")).toBe("fill: red; stroke: url(#a)");
    for (const css of [
      "background: url(https://x/y)",
      "background: url( 'https://x/y' )",
      "@import 'x.css'",
      "@im/**/port 'x.css'",
      "background: u\\72l(https://x)",
      "background-image: image-set('x.png' 1x)",
      "width: expression(alert(1))",
      "@font-face { font-family: x; src: local(x) }",
      "a { color: red /* unterminated",
    ]) {
      expect(CmuxMarkdownSanitizer.sanitizeCSS(css)).toBeNull();
    }
  });

  test("deeply nested input does not overflow the stack", () => {
    const depth = 1_000;
    const root = sanitize(`${"<div>".repeat(depth)}x${"</div>".repeat(depth)}`);
    expect(root.textContent).toBe("x");
  });

  test("URL attributes go through the profile policy", () => {
    const profile = CmuxMarkdownSanitizer.markdownProfile({
      url: ({ tag, name, value }) => (tag === "a" && name === "href" && value.startsWith("https:") ? value : null),
    });
    const root = sanitize(
      '<a href="https://ok">a</a><a href="javascript:alert(1)">b</a><img src="https://x/y.png">',
      profile,
    );
    expect(root.innerHTML).toBe(
      '<a href="https://ok" rel="noopener noreferrer">a</a><a rel="noopener noreferrer">b</a><img>',
    );
  });
});
