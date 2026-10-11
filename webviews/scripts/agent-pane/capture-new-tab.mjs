// Renders the agent pane's new tab page (NewTabPage.tsx) in a headless Chromium with the
// bridge in mock mode, themed the way Swift themes it, for iterating on its look:
//   bun scripts/agent-pane/capture-new-tab.mjs [--theme "Catppuccin Mocha"] [--kind agent] [--out DIR]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");
const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const themeName = arg("theme", "Catppuccin Mocha");
const out = arg("out", path.join(os.tmpdir(), "cmux-new-tab"));
const kinds = arg("kind", "terminal,browser,agent").split(",");
const width = Number(arg("width", 1100));
const height = Number(arg("height", 720));

/// A Ghostty theme file from Resources/ghostty/themes as `agentPaneTheme` input.
function ghosttyTheme(name) {
  const file = path.resolve(webviews, "..", "Resources/ghostty/themes", name);
  const hex = (text) => {
    const value = parseInt(text.replace("#", ""), 16);
    return { r: ((value >> 16) & 255) / 255, g: ((value >> 8) & 255) / 255, b: (value & 255) / 255, a: 1 };
  };
  const input = { ...ghosttyDefault, palette: [...ghosttyDefault.palette] };
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const [key, value] = line.split("=").map((part) => part.trim());
    if (key === "background") input.background = hex(value);
    else if (key === "foreground") input.foreground = hex(value);
    else if (key === "palette") {
      const [index, color] = line
        .slice(line.indexOf("=") + 1)
        .trim()
        .split("=");
      input.palette[Number(index)] = hex(color);
    }
  }
  return input;
}

fs.mkdirSync(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, strictPort: false },
  logLevel: "error",
});
await server.listen();
const url = server.resolvedUrls.local[0];
const theme = agentPaneTheme(ghosttyTheme(themeName));
const browser = await chromium.launch();
try {
  for (const kind of kinds) {
    const context = await browser.newContext({
      viewport: { width, height },
      deviceScaleFactor: 2,
      colorScheme: theme.isDark ? "dark" : "light",
    });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(
      (handshake) => {
        window.cmuxAcpmuxActions = { ready: async () => handshake };
      },
      {
        protocolVersion: 1,
        transport: "mock",
        newSession: true,
        newTab: { kind, cwd: "~/code/cmux", hotkeys: { terminal: "⌃⇧⌘T", browser: "⇧⌘L", agent: "⇧⌘I" } },
      },
    );
    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.cmuxAcpmuxBridge && document.querySelector(".acpmux-newtab-card"));
    await page.evaluate((value) => window.cmuxAcpmuxBridge.applyTheme(value), theme);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(300);
    const file = path.join(out, `new-tab-${kind}.png`);
    await page.screenshot({ path: file, animations: "disabled", caret: "hide" });
    if (errors.length) throw new Error(`the page threw: ${errors.join("; ")}`);
    console.log(file);
    await context.close();
  }
} finally {
  await browser.close();
  await server.close();
}
