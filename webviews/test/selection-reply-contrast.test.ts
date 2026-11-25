// The selection's Reply chip reads over whatever transcript is under it (Leo 2026-11-07: "this reply,
// it has too little opacity here"). Over a see-through window the chip once drew 4% of the text color
// on a clear page and its 60% label sank into the bubbles under it. Its fill is now a veil of the
// theme's solid surface (conversation.css .cv-selection-reply, --cv-selection-reply-veil) and its
// label the full text color: the label must reach 4.5:1 (WCAG text) on the veil composited over the
// worst backdrops it can float over (black, white, and a user bubble on the page), in a dark and a
// light theme, opaque and see-through. The blur under the veil only helps and is not counted.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import { agentPaneTheme, themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { contrast, mix, type RGB } from "../src/theme/color";

const CSS = fs.readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);

function veil(): number {
  const rule = CSS.slice(CSS.indexOf(".cv-selection-reply {"));
  const value = rule.match(/--cv-selection-reply-veil:\s*([\d.]+)%/);
  if (!value) throw new Error("conversation.css has no --cv-selection-reply-veil on .cv-selection-reply");
  return Number(value[1]) / 100;
}

function rgb(text: string): RGB {
  const hex = text.trim().match(/^#([\da-f]{6})/i);
  if (hex) {
    const n = Number.parseInt(hex[1]!, 16);
    return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
  }
  const parts = text.match(/rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/);
  if (!parts) throw new Error(`not a color: ${text}`);
  return { r: Number(parts[1]) / 255, g: Number(parts[2]) / 255, b: Number(parts[3]) / 255 };
}

const palette = (hexes: string[]) => hexes.map((hex, index) => `palette = ${index}=${hex}`).join("\n");
const THEMES: [string, string][] = [
  [
    "Catppuccin Mocha",
    `background = #1e1e2e\nforeground = #cdd6f4\n${palette(["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de", "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"])}\n`,
  ],
  [
    "Rose Pine Dawn",
    `background = #faf4ed\nforeground = #575279\n${palette(["#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279", "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279"])}\n`,
  ],
];

const BLACK: RGB = { r: 0, g: 0, b: 0 };
const WHITE: RGB = { r: 1, g: 1, b: 1 };

test("the Reply chip's label reads at 4.5:1 or more over any backdrop, dark and light, opaque and see-through", () => {
  const amount = veil();
  const failures: string[] = [];
  for (const [name, source] of THEMES) {
    const tokens = themeTokens(parseGhosttyTheme(name, source)!);
    for (const seeThrough of [false, true]) {
      const surface = rgb(webThemePayload(tokens, undefined, seeThrough).variables["--cmux-surface-solid"]!);
      const label = rgb(String(agentPaneTheme(tokens, false, seeThrough).text));
      // A user bubble is 5% of the text over the page (conversation.css --cv-bubble).
      const bubble = mix(surface, label, 0.05);
      for (const [under, backdrop] of [
        ["black", BLACK],
        ["white", WHITE],
        ["a bubble", bubble],
      ] as const) {
        const fill = mix(backdrop, surface, amount);
        const ratio = contrast(label, fill);
        if (ratio < 4.5)
          failures.push(`${name}${seeThrough ? " see-through" : ""} over ${under}: ${ratio.toFixed(2)}:1`);
      }
    }
  }
  expect(failures).toEqual([]);
});
