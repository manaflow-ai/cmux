import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "bun:test";
import { parseHTML } from "linkedom";

type ShellWindow = Window &
  typeof globalThis & {
    __cmuxRenderMarkdown: (markdown: string) => void;
    __cmuxRenderedHTML: () => string;
    __cmuxRenderedText: () => string;
    hljs: unknown;
    marked: unknown;
    webkit: {
      messageHandlers: {
        cmuxLib: {
          postMessage: (message: unknown) => void;
        };
      };
    };
  };

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const shellHTMLPath = join(repoRoot, "Resources/markdown-viewer/shell.html");

const shellStrings = {
  remoteImageBlocked: "Remote image blocked",
  remoteImageConsentMessage:
    "cmux will not contact this image URL until you load this image.",
  remoteImageLoadImage: "Load this image",
  remoteImageLoading: "Loading",
  remoteImageHTTPSOnly: "Only HTTPS remote images can be loaded in the viewer.",
  remoteImageCopyURL: "Copy image URL",
  remoteImageCopied: "Copied",
  remoteImageOpenURL: "Open image URL",
  remoteImageNotAllowed:
    "This remote image URL cannot be loaded in the viewer.",
  remoteImageURL: "Image URL: {url}",
};

function loadMarked() {
  const scope: { marked?: unknown } = {};
  new Function(
    "exports",
    "module",
    "define",
    "globalThis",
    "self",
    readFileSync(
      join(repoRoot, "Resources/markdown-viewer/marked.min.js"),
      "utf8",
    ),
  )(undefined, undefined, undefined, scope, scope);
  if (!scope.marked) throw new Error("marked asset did not load");
  return scope.marked;
}

function loadHighlightJS() {
  return new Function(
    readFileSync(
      join(repoRoot, "Resources/markdown-viewer/highlight.min.js"),
      "utf8",
    ) + "; return hljs;",
  )();
}

function shellApplicationScript() {
  const scripts = Array.from(
    readFileSync(shellHTMLPath, "utf8").matchAll(
      /<script>([\s\S]*?)<\/script>/g,
    ),
    (match) => match[1],
  );
  const appScript = scripts.at(-1);
  if (!appScript) throw new Error("markdown shell application script missing");
  return appScript.replace(
    "{{localizedStringsJSON}}",
    JSON.stringify(shellStrings),
  );
}

function installTemplateShim(document: Document) {
  const nativeCreateElement = document.createElement.bind(document);
  document.createElement = ((
    name: string,
    options?: ElementCreationOptions,
  ) => {
    if (name.toLowerCase() !== "template") {
      return nativeCreateElement(name, options);
    }

    const wrapper = nativeCreateElement("div");
    return {
      content: wrapper,
      get innerHTML() {
        return wrapper.innerHTML;
      },
      set innerHTML(value: string) {
        wrapper.innerHTML = String(value ?? "");
      },
    } as unknown as HTMLElement;
  }) as typeof document.createElement;
}

function createMarkdownShell() {
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const originalNavigator = Object.getOwnPropertyDescriptor(
    globalThis,
    "navigator",
  );
  const { window, document } = parseHTML(
    '<!doctype html><html><head><style id="hljs-light"></style><style id="hljs-dark" disabled></style></head><body><article id="content" class="markdown-body"></article></body></html>',
  ) as unknown as { window: ShellWindow; document: Document };
  installTemplateShim(document);

  const copiedURLs: string[] = [];
  const openedURLs: Array<{ url: string; target: string; features: string }> =
    [];
  const navigator = {
    clipboard: {
      writeText(value: string) {
        copiedURLs.push(String(value));
        return Promise.resolve();
      },
    },
  };
  Object.defineProperty(document, "baseURI", {
    value: "file:///tmp/README.md",
  });
  document.elementFromPoint = () => null;

  Object.assign(window, {
    Array,
    Date,
    Error,
    Math,
    MouseEvent: window.Event,
    NodeFilter: { SHOW_ELEMENT: 1 },
    Number,
    Object,
    Promise,
    RegExp,
    String,
    URL,
    decodeURIComponent,
    encodeURIComponent,
    hljs: loadHighlightJS(),
    innerHeight: 600,
    innerWidth: 800,
    isFinite,
    marked: loadMarked(),
    matchMedia: () => ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }),
    open: (url: string, target?: string, features?: string) => {
      openedURLs.push({
        url: String(url),
        target: String(target || ""),
        features: String(features || ""),
      });
      return null;
    },
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    },
    scrollTo: () => {},
    setTimeout: () => 1,
    clearTimeout: () => {},
    webkit: {
      messageHandlers: {
        cmuxLib: {
          postMessage: () => {},
        },
      },
    },
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: navigator,
  });

  new Function(
    "window",
    "document",
    "NodeFilter",
    "URL",
    "marked",
    "hljs",
    "navigator",
    "encodeURIComponent",
    "decodeURIComponent",
    "isFinite",
    shellApplicationScript(),
  )(
    window,
    document,
    window.NodeFilter,
    URL,
    window.marked,
    window.hljs,
    navigator,
    encodeURIComponent,
    decodeURIComponent,
    isFinite,
  );

  return {
    window,
    document,
    copiedURLs,
    openedURLs,
    cleanup() {
      Object.defineProperty(globalThis, "setTimeout", {
        configurable: true,
        value: originalSetTimeout,
      });
      Object.defineProperty(globalThis, "clearTimeout", {
        configurable: true,
        value: originalClearTimeout,
      });
      if (originalNavigator) {
        Object.defineProperty(globalThis, "navigator", originalNavigator);
      } else {
        delete (globalThis as { navigator?: unknown }).navigator;
      }
    },
  };
}

function placeholderForImage(document: Document, alt: string) {
  const image = document.querySelector(`img[alt="${alt}"]`);
  const id = image?.getAttribute("data-cmux-remote-placeholder-id");
  const placeholder = id
    ? document.querySelector(`[data-cmux-remote-placeholder-for="${id}"]`)
    : null;
  if (!image || !placeholder)
    throw new Error(`missing remote image placeholder for ${alt}`);
  return { image, placeholder };
}

describe("markdown shell local image handling", () => {
  test("rewrites only relative local image sources", () => {
    const { window, document, cleanup } = createMarkdownShell();

    try {
      window.__cmuxRenderMarkdown(`
![Local pixel](images/pixel.png)
![Traversal pixel](../outside.png)
![Explicit file pixel](file:///tmp/outside.png)
![Root absolute pixel](/tmp/outside.png)
`);

      const localImage = document.querySelector('img[alt="Local pixel"]');
      expect(localImage?.getAttribute("data-cmux-original-src")).toBe(
        "images/pixel.png",
      );
      expect(localImage?.getAttribute("src")).toBe(
        `cmux-local-image://image?url=${encodeURIComponent(
          "file:///tmp/images/pixel.png",
        )}`,
      );

      const traversalImage = document.querySelector(
        'img[alt="Traversal pixel"]',
      );
      expect(traversalImage?.getAttribute("data-cmux-original-src")).toBe(
        "../outside.png",
      );
      expect(traversalImage?.getAttribute("src")).toBe(
        `cmux-local-image://image?url=${encodeURIComponent(
          "file:///outside.png",
        )}`,
      );

      const explicitFileImage = document.querySelector(
        'img[alt="Explicit file pixel"]',
      );
      expect(explicitFileImage?.getAttribute("src")).toBeNull();
      expect(explicitFileImage?.hasAttribute("data-cmux-original-src")).toBe(
        false,
      );

      const rootAbsoluteImage = document.querySelector(
        'img[alt="Root absolute pixel"]',
      );
      expect(rootAbsoluteImage?.getAttribute("src")).toBeNull();
      expect(rootAbsoluteImage?.hasAttribute("data-cmux-original-src")).toBe(
        false,
      );
    } finally {
      cleanup();
    }
  });

  test("keeps safe data image sources", () => {
    const { window, document, cleanup } = createMarkdownShell();
    const dataURL = "data:image/png;base64,AA==";

    try {
      window.__cmuxRenderMarkdown(`![Inline pixel](${dataURL})`);

      const image = document.querySelector('img[alt="Inline pixel"]');
      expect(image?.getAttribute("src")).toBe(dataURL);
    } finally {
      cleanup();
    }
  });
});

describe("markdown shell scroll handling", () => {
  test("keeps the visible heading anchored after content updates", () => {
    const { window, document, cleanup } = createMarkdownShell();
    const elementPrototype = window.HTMLElement.prototype;
    const originalGetBoundingClientRect =
      elementPrototype.getBoundingClientRect;
    let scrollY = 480;

    function markdown(extraBeforeSection20: boolean) {
      const lines: string[] = [];
      for (let section = 1; section <= 30; section++) {
        if (section === 20 && extraBeforeSection20) {
          for (let line = 0; line < 8; line++) {
            lines.push(`Inserted external edit line ${line}.`);
          }
        }
        lines.push(`# Section ${section}`);
        lines.push(`Paragraph for section ${section}.`);
      }
      return lines.join("\n\n");
    }

    Object.defineProperty(window, "scrollY", {
      configurable: true,
      get: () => scrollY,
    });
    Object.defineProperty(document.documentElement, "clientHeight", {
      configurable: true,
      get: () => 600,
    });
    Object.defineProperty(document.documentElement, "scrollHeight", {
      configurable: true,
      get: () => 2_000,
    });
    Object.defineProperty(document.documentElement, "scrollTop", {
      configurable: true,
      get: () => scrollY,
      set: (value) => {
        scrollY = Number(value) || 0;
      },
    });
    document.elementFromPoint = () => document.getElementById("section-20");
    window.scrollTo = (xOrOptions?: number | ScrollToOptions, y?: number) => {
      if (typeof xOrOptions === "object") {
        scrollY = Number(xOrOptions.top) || 0;
      } else {
        scrollY = Number(y) || 0;
      }
    };
    elementPrototype.getBoundingClientRect = function getBoundingClientRect() {
      if ((this as HTMLElement).id === "section-20") {
        const hasInsertedContent = document.body.textContent?.includes(
          "Inserted external edit line",
        );
        const absoluteTop = hasInsertedContent ? 728 : 528;
        return {
          top: absoluteTop - scrollY,
          bottom: absoluteTop - scrollY,
          left: 0,
          right: 0,
          width: 0,
          height: 0,
          x: 0,
          y: absoluteTop - scrollY,
          toJSON: () => ({}),
        } as DOMRect;
      }
      return {
        top: 0,
        bottom: 0,
        left: 0,
        right: 0,
        width: 0,
        height: 0,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      } as DOMRect;
    };

    try {
      window.__cmuxRenderMarkdown(markdown(false));
      expect(scrollY).toBe(480);

      window.__cmuxRenderMarkdown(markdown(true));
      expect(scrollY).toBe(680);
    } finally {
      elementPrototype.getBoundingClientRect = originalGetBoundingClientRect;
      cleanup();
    }
  });
});

function expectedURLText(url: string) {
  return `Image URL: ${url}`;
}

describe("markdown shell remote image handling", () => {
  test("blocks remote images until explicit user action", async () => {
    const { window, document, copiedURLs, openedURLs, cleanup } =
      createMarkdownShell();

    try {
      window.__cmuxRenderMarkdown(`
Inline markdown file marker: \`README.md\`

\`\`\`
README.md
\`\`\`

<style>body { background-image: url(https://images.example.com/style.png); }</style>

<table background="https://images.example.com/background.png"><tr><td background="https://images.example.com/cell.png">legacy background</td></tr></table>

<details><summary>Visible details summary</summary>Hidden details text</details>

![HTTPS remote](https://images.example.com/pixel.png)
[![Linked remote](https://images.example.com/linked.png)](README.md)
![Duplicate linked remote](https://images.example.com/linked.png)
![HTTP remote](http://images.example.com/pixel.png)
![Localhost remote](https://localhost/pixel.png)
![Credential remote](https://user:pass@images.example.com/secret.png)
<img alt="Spoofed internal" data-cmux-remote-src="https%3A%2F%2Fspoof.example%2Fpixel.png">
`);

      const images = Array.from(document.querySelectorAll("img"));
      const placeholders = Array.from(
        document.querySelectorAll(".cmux-remote-image-placeholder"),
      );
      const remoteImageURLs = Array.from(
        document.querySelectorAll(".cmux-remote-image-url"),
        (el) => el.textContent || "",
      );
      const buttons = Array.from(
        document.querySelectorAll(".cmux-remote-image-placeholder button"),
        (el) => el.textContent || "",
      );
      const codeFiles = Array.from(
        document.querySelectorAll("code[data-cmux-file]"),
        (el) => decodeURIComponent(el.getAttribute("data-cmux-file") || ""),
      );

      expect(images).toHaveLength(7);
      expect(placeholders).toHaveLength(6);
      expect(remoteImageURLs).toHaveLength(6);
      expect(remoteImageURLs).toContain(
        expectedURLText("https://images.example.com/pixel.png"),
      );
      expect(
        remoteImageURLs.filter(
          (url) =>
            url === expectedURLText("https://images.example.com/linked.png"),
        ),
      ).toHaveLength(2);
      expect(remoteImageURLs).toContain(
        expectedURLText("http://images.example.com/pixel.png"),
      );
      expect(remoteImageURLs).toContain(
        expectedURLText("https://localhost/pixel.png"),
      );
      expect(remoteImageURLs).toContain(
        expectedURLText("https://user:pass@images.example.com/secret.png"),
      );
      expect(
        buttons.filter((label) => label === shellStrings.remoteImageLoadImage),
      ).toHaveLength(3);
      expect(
        buttons.filter((label) => label === shellStrings.remoteImageCopyURL),
      ).toHaveLength(6);
      expect(
        buttons.filter((label) => label === shellStrings.remoteImageOpenURL),
      ).toHaveLength(6);
      expect(codeFiles).toEqual(["README.md"]);
      expect(
        document.getElementById("content")?.querySelectorAll("style"),
      ).toHaveLength(0);
      expect(
        document.getElementById("content")?.querySelectorAll("[background]"),
      ).toHaveLength(0);

      const managedImages = images.filter((image) =>
        image.hasAttribute("data-cmux-remote-src"),
      );
      expect(managedImages).toHaveLength(6);
      for (const image of managedImages) {
        expect(image.getAttribute("src")).toBeNull();
        expect(image.hasAttribute("hidden")).toBe(true);
      }

      const spoofedImage = document.querySelector(
        'img[alt="Spoofed internal"]',
      );
      expect(spoofedImage?.getAttribute("data-cmux-remote-src")).toBeNull();
      expect(spoofedImage?.hasAttribute("hidden")).toBe(false);
      expect(
        placeholders.some((placeholder) =>
          (placeholder.textContent || "").includes(
            shellStrings.remoteImageConsentMessage,
          ),
        ),
      ).toBe(true);
      expect(
        placeholders.some((placeholder) =>
          (placeholder.textContent || "").includes(
            shellStrings.remoteImageHTTPSOnly,
          ),
        ),
      ).toBe(true);
      expect(
        placeholders.some((placeholder) =>
          (placeholder.textContent || "").includes(
            shellStrings.remoteImageNotAllowed,
          ),
        ),
      ).toBe(true);

      const httpPlaceholder = placeholderForImage(
        document,
        "HTTP remote",
      ).placeholder;
      const httpButtons = Array.from(
        httpPlaceholder.querySelectorAll("button"),
      );
      let observedHTTPButtonClick = false;
      httpButtons[0]?.addEventListener("click", () => {
        observedHTTPButtonClick = true;
      });
      httpButtons[0]?.click();
      expect(observedHTTPButtonClick).toBe(true);
      await Promise.resolve();
      expect(copiedURLs).toEqual(["http://images.example.com/pixel.png"]);

      httpButtons[1]?.click();
      expect(openedURLs[0]).toEqual({
        url: "http://images.example.com/pixel.png",
        target: "_blank",
        features: "noopener",
      });

      const linkedPlaceholder = placeholderForImage(
        document,
        "Linked remote",
      ).placeholder;
      const linkedClickTarget =
        linkedPlaceholder.querySelector("strong") || linkedPlaceholder;
      expect(
        linkedClickTarget.dispatchEvent(
          new window.MouseEvent("click", { bubbles: true, cancelable: true }),
        ),
      ).toBe(false);
      expect(linkedPlaceholder.closest("a")).toBeNull();

      const linkedLoadButton = linkedPlaceholder.querySelector(
        'button[data-cmux-remote-action="load"]',
      );
      (linkedLoadButton as HTMLButtonElement | null)?.click();
      const rewrittenLinkedImages = Array.from(
        document.querySelectorAll('img[alt*="linked remote" i]'),
      );
      expect(
        rewrittenLinkedImages.map((image) => image.getAttribute("src")),
      ).toEqual([
        "cmux-remote-image://image?url=https%3A%2F%2Fimages.example.com%2Flinked.png",
        "cmux-remote-image://image?url=https%3A%2F%2Fimages.example.com%2Flinked.png",
      ]);
      expect(linkedLoadButton?.textContent).toBe(
        shellStrings.remoteImageLoading,
      );
      expect((linkedLoadButton as HTMLButtonElement | null)?.disabled).toBe(
        true,
      );

      const cleanedHTML = window.__cmuxRenderedHTML();
      expect(cleanedHTML).toContain('alt="HTTPS remote"');
      expect(cleanedHTML).toContain(
        'src="https://images.example.com/pixel.png"',
      );
      expect(cleanedHTML).not.toContain("cmux-remote-image-placeholder");
      expect(window.__cmuxRenderedText()).not.toContain(
        shellStrings.remoteImageBlocked,
      );
    } finally {
      cleanup();
    }
  });
});
