import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { JSDOM } from "jsdom";

test("packaged math shell executes without external script assets", async () => {
  const html = await readFile(new URL("../../Resources/markdown-viewer/webviews-app/terminal-latex.html", import.meta.url), "utf8");
  const dom = new JSDOM(html);
  const script = dom.window.document.querySelector('script[type="module"]')?.textContent ?? "";
  const digest = createHash("sha256").update(script).digest("base64");
  const policy = dom.window.document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute("content");
  expect(policy).toContain(`script-src 'sha256-${digest}'`);
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const previousDocument = Object.getOwnPropertyDescriptor(globalThis, "document");
  const directory = await mkdtemp(join(tmpdir(), "cmux-latex-bundle-"));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  try {
    const modulePath = join(directory, "terminal-latex.mjs");
    await writeFile(modulePath, script);
    await import(pathToFileURL(modulePath).href);
    const runtime = dom.window as unknown as { updateTerminalLatex: (preview: unknown) => void };
    runtime.updateTerminalLatex({
      equations: [{ source: "x^2", display: false,
        regions: [{ row: 0, column: 0, width: 5, height: 1 }],
        layout: { row: 0, column: 0, width: 5, height: 1 } }],
      cellWidth: 8, cellHeight: 20, paddingLeft: 0, paddingTop: 0,
      foreground: "#fff", background: "#000",
    });
    expect(dom.window.document.querySelector("math msup")).not.toBeNull();
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else Reflect.deleteProperty(globalThis, "window");
    if (previousDocument) Object.defineProperty(globalThis, "document", previousDocument);
    else Reflect.deleteProperty(globalThis, "document");
    dom.window.close();
    await rm(directory, { recursive: true });
  }
});
