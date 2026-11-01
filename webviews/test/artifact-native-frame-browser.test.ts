// A passive document in the native artifact frame, in a real browser. That frame's own policy allows
// inline script (Run uses it), and it writes the document it is sent into itself
// (AgentPaneRenderFrame.swift, PageArtifactFrame.swift). Markup that passed artifactNeedsRun can still
// carry a handler the check's fragment parse never sees (`<body onload>`), so the document the
// inline preview and the side panel send carries its own policy that runs no script
// (previewDocument.ts nativePassiveHtml). The frame's own height report must still arrive.
//
// The frame here is each Swift host's bootstrap document as written, served under that host's
// artifact policy. Real Chromium and WebKit from Playwright; CI fails the file when they cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import { chromium, webkit, type Browser } from "playwright";
import { inertDocument, nativePassiveHtml } from "../src/agent-session/acpmux/conversation/previewDocument";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("artifact-native-frame-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  /// A Swift host's frame document and artifact policy, read from its source.
  function host(file: string, policy: RegExp) {
    const swift = readFileSync(new URL(`../../Packages/macOS/CmuxNext/Sources/${file}`, import.meta.url), "utf8");
    const document = /static let document = Data\(#"""\n([\s\S]*?)\n\s*"""#\.utf8\)/.exec(swift)?.[1];
    const found = policy.exec(swift);
    if (!document || !found) throw new Error(`${file}: no frame document or artifact policy`);
    const csp = found[1]!.includes('",')
      ? [...found[1]!.matchAll(/"([^"]+)"/g)].map((match) => match[1]).join("; ")
      : found[1]!;
    return { document, csp };
  }
  const hosts = {
    "cmux-agent": host(
      "CmuxNextAgentPane/AgentPaneRenderFrame.swift",
      /static let artifactPolicy = \[([\s\S]*?)\]\.joined/,
    ),
    "cmux-page": host("CmuxNextPages/PageArtifactFrame.swift", /static let csp = "([^"]+)"/),
  };
  const FRAME = "https://artifact-frame.invalid/artifact";
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  /// Frames `name`'s document in a sandboxed frame, sends it `html` once it is ready and collects its
  /// messages until the height reports (and a moment more, for a late handler).
  async function draw(engine: string, name: keyof typeof hosts, html: string) {
    const page = await browsers.get(engine)!.newPage();
    const { document, csp } = hosts[name];
    await page.route(FRAME, (route) =>
      route.fulfill({
        status: 200,
        contentType: "text/html; charset=utf-8",
        headers: { "content-security-policy": csp.replace(/frame-ancestors [^;]+;?\s*/, "") },
        body: document,
      }),
    );
    await page.setContent("<body></body>");
    const messages = await page.evaluate(
      ({ src, html }) =>
        new Promise<{ type?: string }[]>((resolve) => {
          const got: { type?: string }[] = [];
          const frame = document.createElement("iframe");
          addEventListener("message", (event) => {
            if (event.source !== frame.contentWindow) return;
            got.push(event.data);
            if (event.data?.type === "cmux-render-ready")
              frame.contentWindow!.postMessage({ type: "cmux-render", html, css: "" }, "*");
            if (event.data?.type === "cmux-render-size") setTimeout(() => resolve(got), 300);
          });
          frame.setAttribute("sandbox", "allow-scripts");
          frame.src = src;
          document.body.append(frame);
        }),
      { src: FRAME, html },
    );
    await page.close();
    return messages;
  }

  // Each passes artifactNeedsRun (its fragment parse drops `<body>`'s and `<html>`'s attributes).
  const RAN = `parent.postMessage({type:'probe-ran'},'*')`;
  const DOCUMENTS = [
    `<body onload="${RAN}"><p>preview</p></body>`,
    `<!doctype html><html onclick="${RAN}"><body onpageshow="${RAN}"><p>preview</p></body></html>`,
  ];

  for (const engine of ["chromium", "webkit"])
    for (const name of Object.keys(hosts) as (keyof typeof hosts)[])
      test(`${engine}, ${name} host: a passive document's handlers never run, and the height still reports`, async () => {
        for (const code of DOCUMENTS) {
          // As the pane makes it (inertDocument; in the pane artifactNeedsRun's template parse passes
          // these, while this runner, with no DOM, falls back to its stricter source check).
          const inert = inertDocument(code);
          const messages = await draw(engine, name, nativePassiveHtml(inert));
          expect(messages.some((message) => message.type === "probe-ran")).toBe(false);
          expect(messages.some((message) => message.type === "cmux-render-size")).toBe(true);
          // The control: the same inert document without that policy does run its handler there, so
          // this harness sees one when it runs (the hole the router review found on cmux#31174).
          if (code !== DOCUMENTS[0]) continue;
          const control = await draw(engine, name, inert);
          expect(control.some((message) => message.type === "probe-ran")).toBe(true);
        }
      });

  test("the policy goes after a doctype, so a document keeps its standards mode", () => {
    expect(nativePassiveHtml("<!DOCTYPE html><p>x</p>")).toStartWith("<!DOCTYPE html><meta ");
    expect(nativePassiveHtml("<p>x</p>")).toStartWith("<meta ");
  });
});
