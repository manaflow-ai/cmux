// The app's own Reduce Motion (Calm mode included) reaches the pane as a theme whose move step is 0
// while its fades stay on: the send moves nothing and fades on the fade setting
// (shared/theme.ts `--agent-motion-send-fade`; send-motion-reduced.test.ts reads the stylesheet's
// clocks in Chromium). Review of #38159, F1.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { MOTION_MS, MOTION_SEND_MS } from "../src/motion/scale.generated";
import { settleReact } from "./support/domTeardown";

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
    await settleReact();
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
