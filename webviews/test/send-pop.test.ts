// A sent prompt pops in where it sits (conversation.css SEND-POP; Leo 2026-11-22: "it does a little pop
// and settle"): Claude's own user-message entrance, on transform alone, on the scale's send-pop step.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import {
  MOTION_EASE_SEND_POP,
  MOTION_SEND_MS,
  MOTION_SEND_POP_FROM,
  MOTION_SEND_POP_MS,
} from "../src/motion/scale.generated";

const css = fs.readFileSync(
  path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);
const keyframes = (name: string) => {
  const start = css.indexOf(`@keyframes ${name} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf("\n}\n", start));
};
const at = (x1: number, y1: number, x2: number, y2: number, x: number) => {
  let lo = 0;
  let hi = 1;
  for (let step = 0; step < 60; step++) {
    const t = (lo + hi) / 2;
    const bx = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t * t * x2 + t ** 3;
    if (bx < x) lo = t;
    else hi = t;
  }
  const t = (lo + hi) / 2;
  return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t * t * y2 + t ** 3;
};

describe("sent prompt pop", () => {
  test("is Claude's cds-um-enter: 450 ms, cubic-bezier(.34, 1.3, .64, 1), from scale .92 and 6px low", () => {
    expect(MOTION_SEND_POP_MS).toBe(450);
    expect(MOTION_EASE_SEND_POP).toBe("cubic-bezier(0.34, 1.3, 0.64, 1)");
    expect(MOTION_SEND_POP_FROM).toEqual({ scale: 0.92, rise: 6 });
    const from = keyframes("cv-send-pop");
    expect(from).toContain(`scale(${MOTION_SEND_POP_FROM.scale}) translateY(${MOTION_SEND_POP_FROM.rise}px)`);
  });

  test("passes its size and settles back: a pop, not a plain ease", () => {
    const [x1, y1, x2, y2] = MOTION_EASE_SEND_POP.match(/[\d.]+/g)!.map(Number) as [number, number, number, number];
    const samples = Array.from({ length: 46 }, (_, index) => at(x1, y1, x2, y2, index / 45));
    const peak = Math.max(...samples);
    const peakMs = (samples.indexOf(peak) / 45) * MOTION_SEND_POP_MS;
    expect(peak).toBeGreaterThan(1.02);
    expect(peak).toBeLessThan(1.04);
    expect(peakMs).toBeGreaterThan(250);
    expect(peakMs).toBeLessThan(350);
    expect(samples.at(-1)).toBeCloseTo(1, 3);
  });

  test("moves transform alone (compositor), on the presentation wrapper of the sent prompt only", () => {
    for (const name of ["cv-send-pop", "cv-send-pop-spring"]) {
      const frames = keyframes(name);
      expect(frames).not.toMatch(/\b(width|height|top|left|margin|padding|clip-path|filter)\s*:/);
    }
    const rule = css.match(
      /:where\(\[data-send-pop\]:not\(\[data-send-pop="none"\]\)\)\s+\.acpmux-user\.acpmux-row--message-enter:not\(\.acpmux-row--line, \[data-send-morphed\]\)\s+> \.acpmux-row__message-presentation \{([^}]*)\}/,
    );
    expect(rule?.[1]).toContain("cv-send-pop var(--agent-motion-send-pop");
    expect(rule?.[1]).toContain("var(--cmux-ease-send-pop");
    expect(rule?.[1]).toContain("transform-origin: right center");
  });

  test("is off unless switched on: the rule plays only under the setting's data-send-pop gate", () => {
    // Leo, 2026-11-22: "hm im not necessarily sure if people will be wanting to do the send pop by default".
    const block = css.slice(css.indexOf("@keyframes cv-send-pop-spring"));
    // Each rule that plays the pop, by its selector: the text before its own "{", after the rule, block
    // or comment before it.
    const pops = [...block.matchAll(/animation:\s*cv-send-pop\b/g)].map((match) => {
      const head = block.slice(0, match.index);
      const selector = head.slice(0, head.lastIndexOf("{"));
      return selector.slice(
        Math.max(selector.lastIndexOf("}"), selector.lastIndexOf("{"), selector.lastIndexOf("*/")) + 1,
      );
    });
    expect(pops.length).toBe(1);
    for (const selector of pops) expect(selector).toContain(':where([data-send-pop]:not([data-send-pop="none"]))');
    const schema = JSON.parse(
      fs.readFileSync(path.join(import.meta.dir, "../../schemas/settings/source/agent-pane-display.json"), "utf8"),
    );
    const find = (node: unknown): { default?: unknown; kind?: string } | undefined => {
      if (Array.isArray(node)) return node.map(find).find(Boolean);
      if (node && typeof node === "object") {
        const record = node as Record<string, unknown>;
        if (record.key === "agentPane.display.sendPop") return record as { default?: unknown; kind?: string };
        return Object.values(record).map(find).find(Boolean);
      }
      return undefined;
    };
    expect(find(schema)).toMatchObject({ kind: "toggle", default: false });
  });

  test("the setting sets the gate on the root, and clears it off", async () => {
    const { JSDOM } = await import("jsdom");
    const scope = globalThis as Record<string, unknown>;
    const saved = scope.document;
    scope.document = new JSDOM("<!doctype html>").window.document;
    try {
      const { SEND_POP_KEY, sendPopEnabled, setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
      const root = (scope.document as Document).documentElement;
      setChatDisplay({});
      expect(root.hasAttribute("data-send-pop")).toBe(false);
      expect(sendPopEnabled()).toBe(false);
      setChatDisplay({ [SEND_POP_KEY]: true });
      expect(root.getAttribute("data-send-pop")).toBe("claude");
      expect(sendPopEnabled()).toBe(true);
      setChatDisplay({ [SEND_POP_KEY]: false });
      expect(root.hasAttribute("data-send-pop")).toBe(false);
      expect(sendPopEnabled()).toBe(false);
    } finally {
      scope.document = saved;
    }
  });

  test("the room, the thread and the thinking row still land at once", () => {
    expect(MOTION_SEND_MS).toBe(0);
  });
});
