// Manual VM check, not a CI lane. Start `bun --bun run gallery:dev`, then:
// ARTIFACT_GALLERY_URL=http://127.0.0.1:4210/gallery/ bun scripts/agent-pane/artifact-browser-check.mjs /tmp/artifact-captures
import { chromium } from "playwright";
import { mkdir } from "node:fs/promises";
import assert from "node:assert/strict";
const out = process.argv[2];
if (out) await mkdir(out, { recursive: true });
const browser = await chromium.launch({ executablePath: process.env.ARTIFACT_CHROMIUM, headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const variants = [
    "interactive-v1",
    "interactive-v2",
    "interactive-v3",
    "jsx",
    "jsx-fragment",
    "svg",
    "claude-write",
    "codex-write",
    "pi-write",
    "gemini-write",
  ];
  for (const variant of variants) {
    const url = new URL("frame.html", process.env.ARTIFACT_GALLERY_URL ?? "http://127.0.0.1:4210/gallery/");
    url.search = new URLSearchParams({
      entry: "agent-pane.artifact-panel",
      source: "src/agent-session/acpmux/conversation/ArtifactPanel.gallery.ts",
      variant,
      width: "1440",
      height: "900",
      colorScheme: "dark",
    }).toString();
    await page.goto(url.href);
    const frame = page.frameLocator(".acpmux-artifact-frame");
    const iframe = page.locator(".acpmux-artifact-frame");
    if (variant === "svg") {
      await frame.locator("circle").waitFor();
      assert.equal(await iframe.getAttribute("sandbox"), "");
      const child = await (await iframe.elementHandle()).contentFrame();
      const loaded = new Promise((resolve) => child.once("load", resolve));
      await iframe.evaluate((element) => {
        element.srcdoc +=
          '<svg/onload="window.__artifactAutoRan=1"></svg>' +
          '<a href="java&#x09;script:window.__artifactAutoRan=1">probe</a>';
      });
      await loaded;
      await frame.locator("a").click();
      assert.equal(await child.evaluate(() => window.__artifactAutoRan), undefined);
    } else {
      await frame.locator("button").click();
      const expected = variant === "jsx" ? "Count 1" : variant.startsWith("interactive") ? variant.slice(-1) : "1";
      await frame.locator("button").filter({ hasText: expected }).waitFor();
      assert.equal(await frame.locator("button").textContent(), expected);
      assert.equal(await iframe.getAttribute("sandbox"), "allow-scripts");
    }
    if (out) await page.screenshot({ path: `${out}/${variant}.png` });
    console.log(`PASS ${variant}: ${url}`);
  }
  // Probe inside the actual rendered frame. Browser policy enforcement, not source assertions.
  const handle = await page.locator(".acpmux-artifact-frame").elementHandle();
  const frame = await handle.contentFrame();
  const escaped = [];
  await page.route("https://artifact-probe.invalid/**", (route) => {
    escaped.push(route.request().url());
    return route.abort();
  });
  page.on("websocket", (socket) => escaped.push(socket.url()));
  const result = await frame.evaluate(async () => {
    const denied = async (action) => {
      try {
        await action();
        return false;
      } catch {
        return true;
      }
    };
    const resource = (tag, attribute) =>
      new Promise((resolve) => {
        const node = document.createElement(tag);
        node.onload = () => resolve(false);
        node.onerror = () => resolve(true);
        node[attribute] = "https://artifact-probe.invalid/probe";
        document.body.append(node);
      });
    return {
      parent: await denied(() => parent.document.body),
      storage: await denied(() => localStorage.getItem("probe")),
      network: await denied(() => fetch("https://artifact-probe.invalid/fetch")),
      file: await denied(() => fetch("file:///tmp/artifact-private")),
      websocket: await new Promise((resolve) => {
        const socket = new WebSocket("wss://artifact-probe.invalid/socket");
        socket.onopen = () => {
          socket.close();
          resolve(false);
        };
        socket.onerror = () => resolve(true);
      }),
      image: await resource("img", "src"),
      script: await resource("script", "src"),
    };
  });
  assert.ok(Object.values(result).every(Boolean), JSON.stringify(result));
  assert.deepEqual(escaped, []);
  console.log(`PASS opaque origin and resource policy: ${JSON.stringify(result)}`);
  console.log("Native self-navigation refusal requires AgentPaneArtifactNavigationTests and WKWebView dogfood.");
} finally {
  await browser.close();
}
