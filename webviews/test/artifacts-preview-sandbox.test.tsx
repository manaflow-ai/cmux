// The Artifacts page's HTML preview keeps the strict CSP and `sandbox=""` on every frame (review
// follow-up on #29837, I35446-4): WebKit has no subresource lockdown for srcdoc frames the way the CEF
// shim does, so the frame's own sandbox and the document's CSP are what keep a saved document from
// running script, reaching the page or its bridge, or touching the network.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { FileBody } from "../src/pages/artifacts/ArtifactsPage";
import type { Strings } from "../src/pages/shared/i18n";

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key } as Strings;

function frameOf(file: Parameters<typeof FileBody>[0]["file"]): HTMLIFrameElement {
  const html = renderToStaticMarkup(<FileBody file={file} strings={strings} />);
  const frame = new JSDOM(`<body>${html}</body>`).window.document.querySelector("iframe");
  expect(frame).not.toBeNull();
  return frame as HTMLIFrameElement;
}

for (const [label, file] of [
  ["by content type", { path: "notes/a.txt", size: 10, contentType: "text/html; charset=utf-8", commit: "c1" }],
  ["by extension", { path: "docs/page.html", size: 10, contentType: "application/octet-stream", commit: "c2" }],
] as const) {
  test(`an HTML preview (${label}) is a fully sandboxed srcdoc frame under the strict CSP`, () => {
    const frame = frameOf({ ...file, content: "<script>parent.postMessage(1,'*')</script><h1>hi</h1>" });
    // An empty sandbox: no scripts, no same-origin, no forms, popups or top navigation.
    expect(frame.getAttribute("sandbox")).toBe("");
    expect(frame.getAttribute("referrerpolicy")).toBe("no-referrer");
    expect(frame.hasAttribute("src")).toBe(false);
    const doc = frame.getAttribute("srcdoc") ?? "";
    const policy = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/.exec(doc)?.[1] ?? "";
    expect(doc.startsWith(`<!doctype html><meta http-equiv="Content-Security-Policy"`)).toBe(true);
    for (const directive of [
      "default-src 'none'",
      "connect-src 'none'",
      "frame-src 'none'",
      "form-action 'none'",
      "base-uri 'none'",
    ])
      expect(policy).toContain(directive);
    expect(policy).not.toMatch(/https?:|\*/);
    // The saved document follows the policy, so it cannot lift it.
    expect(doc.indexOf("Content-Security-Policy")).toBeLessThan(doc.indexOf("<script>"));
  });
}
