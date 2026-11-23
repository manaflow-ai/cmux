// Theme hooks for the composer, its hat and the in-page split edge: a public custom property read
// with today's value as its fallback, so with no theme setting it the computed value is byte-for-byte
// what it was. Each case pins the fallback to the literal the declaration held before the hook.
// The settings and theme keys that write these names come from the Rust side (theme surface tokens).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const src = (file: string) => readFileSync(path.resolve(import.meta.dir, "../src", file), "utf8");
/** Whitespace-insensitive, so the minified and the formatted sheets compare alike. */
const squash = (text: string) => text.replace(/\s+/g, "");

interface Hook {
  file: string;
  /** The property the hook feeds. */
  property: string;
  token: string;
  /** The value the property held before the hook: today's default. */
  today: string;
}

const HOOKS: Hook[] = [
  {
    file: "agent-session/acpmux/composerStates.css",
    property: "--acpmux-stack-shadow",
    token: "--cmux-composer-hat-shadow",
    today: "inset 0 0 0 var(--cmux-hairline, 0.5px) var(--acpmux-composer-edge)",
  },
  {
    file: "agent-session/acpmux/composerStates.css",
    property: "--acpmux-stack-shadow",
    token: "--cmux-composer-hat-shadow",
    today: "var(--glass-material-rim), inset 0 0 0 var(--cmux-hairline, 0.5px) var(--acpmux-composer-edge)",
  },
  {
    file: "agent-session/acpmux/styles.css",
    property: "--acpmux-composer-radius",
    token: "--cmux-composer-radius",
    today: "22px",
  },
  {
    file: "agent-session/acpmux/composerLocation.css",
    property: "--acpmux-composer-radius",
    token: "--cmux-composer-radius",
    today: "18px",
  },
  {
    file: "agent-session/acpmux/styles.css",
    property: "--acpmux-composer-edge",
    token: "--cmux-composer-border",
    today: "color-mix(in srgb,var(--agent-text) 22%,var(--agent-page-bg,var(--acpmux-base)))",
  },
  {
    file: "agent-session/acpmux/composerStates.css",
    property: "--acpmux-composer-solid",
    token: "--cmux-composer-fill",
    today:
      "light-dark(color-mix(in srgb, var(--cmux-surface-solid, var(--acpmux-base)) 35%, var(--cmux-tone-light)), color-mix(in srgb, var(--agent-text) 7%, var(--cmux-surface-solid, var(--acpmux-base))))",
  },
  {
    file: "agent-session/acpmux/composerStates.css",
    property: "--acpmux-composer-shadow",
    token: "--cmux-composer-shadow",
    today: "var(--elevation-1)",
  },
  {
    file: "agent-session/acpmux/composerStates.css",
    property: "--acpmux-stack-tint",
    token: "--cmux-composer-hat-fill",
    today: "color-mix(in srgb, var(--acpmux-composer-solid) var(--ds-glass-popover-tint), transparent)",
  },
  {
    file: "agent-session/acpmux/subagents/subagents.css",
    property: "--acpmux-tray-radius",
    token: "--cmux-composer-hat-radius",
    today: "var(--acpmux-composer-radius, var(--grid-composer-radius))",
  },
  {
    file: "agent-session/acpmux/TaskGoalStrip.css",
    property: "--acpmux-goal-radius",
    token: "--cmux-composer-hat-radius",
    today: "var(--acpmux-composer-radius, 11px)",
  },
  { file: "ui/SplitEdge.css", property: "width", token: "--cmux-split-divider-width", today: "2px" },
  {
    file: "ui/SplitEdge.css",
    property: "background",
    token: "--cmux-split-divider-color",
    today: "color-mix(in srgb, var(--cmux-app-focus-ring, var(--agent-border, CanvasText)) 60%, transparent)",
  },
];

describe("theme surface hooks fall back to today's value", () => {
  for (const hook of HOOKS) {
    test(`${hook.token} -> ${hook.property} in ${hook.file}`, () => {
      expect(squash(src(hook.file))).toContain(squash(`${hook.property}: var(${hook.token}, ${hook.today})`));
    });
  }
});
