import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { JSDOM } from "jsdom";

const viewerDir = join(import.meta.dir, "../../Resources/markdown-viewer");

function asset(name: string): string {
  return readFileSync(join(viewerDir, name), "utf8");
}

export function shellHTML(): string {
  const replacements: Record<string, string> = {
    "{{githubMarkdownCSS}}": asset("github-markdown.css"),
    "{{highlightLightCSS}}": asset("highlight-github.css"),
    "{{highlightDarkCSS}}": asset("highlight-github-dark.css"),
    "{{markedJS}}": asset("marked.min.js"),
    "{{highlightJS}}": asset("highlight.min.js"),
    "{{viewerNavigationJS}}": asset("viewer-navigation.js"),
    "{{markdownSanitizerJS}}": safeAsset("markdown-sanitizer.js"),
    "{{localizedStringsJSON}}": "{}",
  };
  let html = asset("shell.html");
  for (const [placeholder, value] of Object.entries(replacements)) {
    html = html.split(placeholder).join(value);
  }
  return html;
}

function safeAsset(name: string): string {
  try {
    return asset(name);
  } catch {
    return "";
  }
}

export type PostedMessage = Record<string, unknown>;

export function loadShell(): { dom: JSDOM; posted: PostedMessage[]; render(markdown: string): HTMLElement } {
  const posted: PostedMessage[] = [];
  // Bun cannot host jsdom's script runner, so evaluate the shell's inline
  // scripts in order with the jsdom window as their global scope.
  const dom = new JSDOM(shellHTML(), { url: "file:///tmp/cmux-markdown-fixture/README.md" });
  const win = dom.window as unknown as Record<string, unknown>;
  const media = { matches: false, addEventListener() {}, removeEventListener() {} };
  win.matchMedia = () => media;
  win.globalThis = win;
  win.self = win;
  win.scrollTo = () => {};
  win.requestAnimationFrame = () => 0;
  win.cancelAnimationFrame = () => {};
  (dom.window.document as unknown as { elementFromPoint: () => null }).elementFromPoint = () => null;
  win.webkit = {
    messageHandlers: {
      cmuxLib: {
        postMessage(message: PostedMessage) {
          posted.push(message);
        },
      },
    },
  };
  // Classic scripts share one global scope, and a top-level `var` (as in
  // highlight.js) becomes a window property. Run them as one body and mirror
  // `hljs` onto the window after each script.
  const body = Array.from(dom.window.document.querySelectorAll("script"))
    .map((script) => `${script.textContent ?? ""}\n;if (typeof hljs !== "undefined") { win.hljs = hljs; }\n`)
    .join("\n");
  // The scripts resolve free names through the jsdom window, as they do in the page.
  runInNewContext(`with (win) {\n${body}\n}`, { win });
  const window = win as unknown as { __cmuxRenderMarkdown(md: string): void };
  return {
    dom,
    posted,
    render(markdown: string) {
      window.__cmuxRenderMarkdown(markdown);
      return dom.window.document.getElementById("content") as HTMLElement;
    },
  };
}

export function unsafeNodes(root: Node): string[] {
  const findings: string[] = [];
  const doc = root.ownerDocument ?? (root as Document);
  const walker = doc.createTreeWalker(root, 0xffffffff);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.nodeType === 8) {
      findings.push(`comment:${node.nodeValue}`);
      continue;
    }
    if (node.nodeType !== 1) {
      continue;
    }
    const element = node as Element;
    const name = element.localName.toLowerCase();
    if (
      [
        "script",
        "noscript",
        "noembed",
        "noframes",
        "xmp",
        "plaintext",
        "iframe",
        "object",
        "embed",
        "template",
        "style",
        "textarea",
        "title",
        "animate",
        "set",
        "animatetransform",
        "animatemotion",
        "foreignobject",
        "form",
        "base",
        "link",
        "meta",
      ].includes(name) &&
      !element.closest(".cmux-mermaid")
    ) {
      findings.push(`element:${name}`);
    }
    for (const attribute of Array.from(element.attributes)) {
      const attrName = attribute.name.toLowerCase();
      const compact = Array.from(attribute.value)
        .filter((character) => character.charCodeAt(0) > 0x20 && character.charCodeAt(0) !== 0x7f)
        .join("")
        .toLowerCase();
      if (attrName.startsWith("on")) {
        findings.push(`attr:${name}[${attrName}]`);
      }
      if (compact.startsWith("javascript:") || compact.startsWith("vbscript:")) {
        findings.push(`url:${name}[${attrName}]=${attribute.value}`);
      }
      if (attrName === "attributename" || attrName === "srcdoc") {
        findings.push(`attr:${name}[${attrName}]`);
      }
    }
  }
  return findings;
}
