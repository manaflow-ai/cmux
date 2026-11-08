// l10n-allow-file: test fixture markup, not shipped UI.
// The app's own Reduce Motion (Calm mode included) reaches the pane as a theme whose move step is 0
// while its fades stay on, and WebKit can still answer `prefers-reduced-motion: no-preference`. A
// sent prompt then keeps a plain fade on the fade setting, and nothing moves: the bubble's edge and
// the thread's rise run the move-scaled send step (0), its fades `--agent-motion-send-fade`
// (shared/theme.ts, conversation.css SEND-ENTRANCE). Review of #38159, F1.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { MOTION_MS, MOTION_SEND_MS } from "../src/motion/scale.generated";

const theme = {
  isDark: false,
  pageBackground: "#fff",
  surfaceBackground: "#fff",
  surfaceElevatedBackground: "#fff",
  inputBackground: "#fff",
  border: "#ddd",
  borderStrong: "#ccc",
  text: "#000",
  mutedText: "#666",
  softText: "#999",
  accent: "#000",
  accentSoft: "#eee",
  danger: "#c00",
  shadow: "#0003",
};
const motion = (move: number, fade: number) => ({
  hover: fade,
  hoverOut: fade,
  focus: fade,
  fadeIn: fade,
  fadeOut: fade,
  move,
});

/// The send tokens the theme writes on the root for `policy`.
async function sendTokens(policy: ReturnType<typeof motion>) {
  const scope = globalThis as Record<string, unknown>;
  const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
  const { window } = new JSDOM("<!doctype html><html><body></body></html>");
  Object.assign(scope, { window, document: window.document });
  try {
    const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
    applyAgentTheme({ ...theme, motion: policy } as Parameters<typeof applyAgentTheme>[0]);
    const style = window.document.documentElement.style;
    return {
      send: style.getPropertyValue("--agent-motion-send"),
      fade: style.getPropertyValue("--agent-motion-send-fade"),
    };
  } finally {
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
}

test("Reduce Motion: the send moves nothing and keeps its fade on the fade setting", async () => {
  expect(await sendTokens(motion(0, 0.12))).toEqual({ send: "0ms", fade: "120ms" });
});

test("full motion: the send's fades run its own clock", async () => {
  const tokens = await sendTokens(motion(MOTION_MS.standard / 1000, 0.12));
  expect(tokens).toEqual({ send: `${MOTION_SEND_MS}ms`, fade: `${MOTION_SEND_MS}ms` });
});

test("animations off: nothing moves or fades", async () => {
  expect(await sendTokens(motion(0, 0))).toEqual({ send: "0ms", fade: "0ms" });
});

await requireBrowserLane("send-motion-reduced.test.ts", async () => {
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-motion-reduced: skipping (run `bunx playwright install chromium`)");
    describe.skip("send entrance under Reduce Motion", () => test("chromium", () => {}));
    return;
  }
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  test("a sent prompt under the app's Reduce Motion fades on the fade setting, its edge never moving", async () => {
    const css = readFileSync(
      path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
      "utf8",
    );
    const page = await browser!.newPage();
    try {
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.setContent(`<!doctype html><html style="--agent-motion-send: 0ms; --agent-motion-send-fade: 120ms; --agent-motion-in: 120ms">
        <body><div class="acpmux-thread">
          <article class="acpmux-row acpmux-user acpmux-row--message-enter"><div class="acpmux-row__message-presentation">
            <div class="cv-user"><img class="cv-user__image cv-enter" alt=""><div class="cv-user__bubble"><p>sent</p></div></div>
          </div></article>
          <article class="acpmux-row acpmux-thinking acpmux-row--enter">Thinking</article>
        </div></body></html>`);
      await page.addStyleTag({ content: css });
      const clocks = await page.evaluate(() => {
        const read = (selector: string) => {
          const style = getComputedStyle(document.querySelector(selector)!);
          return { name: style.animationName, duration: style.animationDuration };
        };
        return {
          row: read(".acpmux-row__message-presentation"),
          thinking: read(".acpmux-thinking"),
          image: read(".cv-user__image"),
          bubble: read(".cv-user__bubble"),
        };
      });
      expect(clocks.row.duration, "the prompt fades on the fade setting").toBe("0.12s");
      expect(clocks.thinking.duration, "the thinking row fades with it").toBe("0.12s");
      expect(clocks.image.duration, "its picture fades with it").toBe("0.12s");
      expect(clocks.bubble.duration, "the bubble's edge does not move").toBe("0s");
    } finally {
      await page.close();
    }
  });
});
