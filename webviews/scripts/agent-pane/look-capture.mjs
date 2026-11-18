// Captures the Claude Code desktop look (look/README.md) in mock mode, themed as the look's profile
// themes it: the warm near-black page, the clay accent, the profile's chat stylesheet.
//
//   node scripts/agent-pane/look-capture.mjs --out DIR
//
// Writes DIR/chat-live.png (a turn mid-way: the live line), DIR/chat-done.png (the finished turn:
// tool rows, your prompt, the branch bar and composer) and DIR/new-tab.png. With --reference IMAGE,
// also DIR/side-NAME.png: the reference on the left, the capture on the right, at one height.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";
import { launchBrowser, settle, startDevServer, stubMockBridge, webviews } from "./mockLaunch.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const out = path.resolve(outIndex >= 0 ? args[outIndex + 1] : "/tmp/look-claude-shots");
fs.mkdirSync(out, { recursive: true });
const referenceIndex = args.indexOf("--reference");
const reference = referenceIndex >= 0 ? path.resolve(args[referenceIndex + 1]) : undefined;

const rgb = (hex) => ({ r: ((hex >> 16) & 255) / 255, g: ((hex >> 8) & 255) / 255, b: (hex & 255) / 255, a: 1 });
const theme = {
  ...agentPaneTheme({ ...ghosttyDefault, background: rgb(0x1f1e1c), foreground: rgb(0xececea) }),
  accent: "rgb(217, 119, 87)",
};
const profileCss = (() => {
  const file = path.resolve(webviews, "../look/files/agent-pane.css");
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
})();
const fixture = JSON.parse(fs.readFileSync(path.join(here, "look-claude-turn.json"), "utf8"));
const size = { width: 900, height: 760 };

const server = await startDevServer("vite.config.acpmux-pane.mjs");
try {
  const browser = await launchBrowser();
  try {
    await live(browser);
    await chat(browser);
    await newTab(browser);
    if (reference) for (const name of ["chat-live", "chat-done", "new-tab"]) await side(browser, name);
  } finally {
    await browser.close();
  }
} finally {
  await server.close();
}

async function open(browser, stub) {
  const context = await browser.newContext({ viewport: size, deviceScaleFactor: 2, colorScheme: "dark" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await stubMockBridge(page, stub);
  // A cold dev server transforms the whole pane on the first load: give it minutes, not seconds.
  await page.goto(server.url, { waitUntil: "load", timeout: 300000 });
  await page.waitForFunction(() => window.cmuxAcpmuxBridge, null, { timeout: 300000 });
  await page.evaluate((value) => window.cmuxAcpmuxBridge.applyTheme(value), theme);
  if (profileCss) await page.addStyleTag({ content: profileCss });
  return { context, page, errors };
}

async function shot(page, name, errors) {
  await page.evaluate(() => document.fonts.ready);
  await settle(page);
  const file = path.join(out, `${name}.png`);
  await page.screenshot({ path: file, animations: "disabled", caret: "hide" });
  if (errors.length) console.log(`${name}: the page threw: ${errors.join("; ")}`);
  console.log(file);
}

async function chat(browser) {
  const { context, page, errors } = await open(browser, {
    script: { steps: fixture.steps, endAtMs: fixture.endAtMs },
  });
  try {
    await page.waitForFunction(() => window.cmuxAcpmuxActions?.["chat.send"], null, { timeout: 120000 });
    await page.evaluate((prompt) => window.cmuxAcpmuxActions["chat.send"]({ text: prompt }), fixture.prompt);
    await page.waitForFunction(() => document.querySelector('.acpmux-scroll [data-row-id^="summary-"]'), null, {
      timeout: 90000,
    });
    await shot(page, "chat-done", errors);
  } finally {
    await context.close();
  }
}

/// The mock's own paced turn (350 ms a step; a recorded script is delivered at once), caught mid-way
/// for the live line.
async function live(browser) {
  const { context, page, errors } = await open(browser, {});
  try {
    await page.waitForFunction(() => window.cmuxAcpmuxActions?.["chat.send"], null, { timeout: 120000 });
    await page.evaluate((prompt) => window.cmuxAcpmuxActions["chat.send"]({ text: prompt }), fixture.prompt);
    await page.waitForSelector(".cv-worked--live", { timeout: 30000 }).catch(() => undefined);
    await page.waitForTimeout(1200);
    await shot(page, "chat-live", errors);
  } finally {
    await context.close();
  }
}

async function newTab(browser) {
  const { context, page, errors } = await open(browser, {
    ready: { newSession: true, newTab: { kind: "agent", cwd: "~/code/acme-web" } },
  });
  try {
    await page.waitForSelector(".nt-screen", { timeout: 20000 }).catch(() => undefined);
    await page.waitForTimeout(500);
    await shot(page, "new-tab", errors);
  } finally {
    await context.close();
  }
}

/// The reference and a capture side by side, both 720 px tall.
async function side(browser, name) {
  const data = (file, type) => `data:${type};base64,${fs.readFileSync(file).toString("base64")}`;
  const kind = reference.endsWith(".png") ? "image/png" : reference.endsWith(".webp") ? "image/webp" : "image/jpeg";
  const context = await browser.newContext({ viewport: { width: 2200, height: 720 }, deviceScaleFactor: 1 });
  try {
    const page = await context.newPage();
    await page.setContent(
      `<body style="margin:0;background:#111;display:flex;gap:8px;width:max-content">` +
        `<img style="height:720px" src="${data(reference, kind)}"><img style="height:720px" src="${data(path.join(out, `${name}.png`), "image/png")}"></body>`,
    );
    await page.evaluate(() => Promise.all([...document.images].map((image) => image.decode())));
    const file = path.join(out, `side-${name}.png`);
    await page.locator("body").screenshot({ path: file });
    console.log(file);
  } finally {
    await context.close();
  }
}
