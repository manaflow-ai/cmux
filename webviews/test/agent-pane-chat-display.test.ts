// The chat's look (chatDisplay.ts, plans/cmux-next/chat-display-settings-DESIGN.md; user 2026-10-20:
// "make almost everything configurable in markdown viewer to be configurable in the [chat] ... max
// width, fonts, ... code fonts configurable separately"):
//   - the chat's own `agentPane.display.*` key wins, then the Markdown viewer's font preset, code
//     font and code size, then the default; sizes and width never follow the viewer;
//   - values outside a row's range clamp, unsafe font names are dropped;
//   - the CSS variables and the row estimator's metrics follow the font size and line height;
//   - the user's width replaces the Debug Settings column trial.
import { describe, expect, test } from "bun:test";
import {
  applyChatDisplay,
  chatDisplayVariables,
  chatMetrics,
  DEFAULT_CHAT_DISPLAY,
  ENVIRONMENT_PLACEMENT_KEY,
  resolveChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import { chatColumnOf } from "../src/agent-session/acpmux/chatWidth";
import { transcriptColumn } from "../src/agent-session/acpmux/model";

describe("chat display resolution", () => {
  test("no keys: today's look, every variable left to the stylesheet", () => {
    const display = resolveChatDisplay({});
    expect(display).toEqual(DEFAULT_CHAT_DISPLAY);
    expect(Object.values(chatDisplayVariables(display)).every((value) => value === null)).toBe(true);
    const metrics = chatMetrics(display);
    expect(metrics.measureFont).toBe('14px "Inter", system-ui, sans-serif');
    expect(metrics.lineHeight).toBe(22.75);
    expect(metrics.codeLineHeight).toBe(20);
    expect(metrics.inlineCodeSize).toBe(13);
    expect(metrics.blockCodeSize).toBe(12);
  });

  test("the chat follows the Markdown viewer's font, code font and code size", () => {
    const display = resolveChatDisplay({
      "markdown.font.preset": "serif",
      "markdown.code.family": "JetBrains Mono",
      "markdown.code.scale": 0.9,
      // Sizes and width are the viewer's own.
      "markdown.font.size": 20,
      "markdown.layout.width": 60,
    });
    expect(display.font).toBe("serif");
    expect(display.codeFamily).toBe("JetBrains Mono");
    expect(display.codeScale).toBe(0.9);
    expect(display.fontSize).toBe(14);
    expect(display.width).toBe(800);
  });

  test("the chat's own keys win over the viewer's", () => {
    const display = resolveChatDisplay({
      "markdown.font.preset": "serif",
      "markdown.code.family": "JetBrains Mono",
      "markdown.code.scale": 0.9,
      "agentPane.display.font.preset": "mono",
      "agentPane.display.code.family": "Berkeley Mono",
      "agentPane.display.code.scale": 1,
    });
    expect(display.font).toBe("mono");
    expect(display.codeFamily).toBe("Berkeley Mono");
    expect(display.codeScale).toBe(1);
  });

  test("`markdown` as the chat's font follows the viewer", () => {
    expect(
      resolveChatDisplay({ "agentPane.display.font.preset": "markdown", "markdown.font.preset": "serif" }).font,
    ).toBe("serif");
  });

  test("out-of-range values clamp; bad types and unsafe names are dropped", () => {
    const display = resolveChatDisplay({
      "agentPane.display.font.size": 400,
      "agentPane.display.font.lineHeight": 0.2,
      "agentPane.display.width": 100,
      "agentPane.display.code.family": 'Menlo"; } body { color: red',
      "agentPane.display.fullWidth": "yes",
    });
    expect(display.fontSize).toBe(28);
    expect(display.lineHeight).toBe(1.2);
    expect(display.width).toBe(480);
    expect(display.codeFamily).toBeNull();
    expect(display.fullWidth).toBe(false);
  });

  test("the environment chip is left by default and accepts right or off", () => {
    expect(resolveChatDisplay({}).environmentPlacement).toBe("left");
    expect(resolveChatDisplay({ [ENVIRONMENT_PLACEMENT_KEY]: "right" }).environmentPlacement).toBe("right");
    expect(resolveChatDisplay({ [ENVIRONMENT_PLACEMENT_KEY]: "off" }).environmentPlacement).toBe("off");
    expect(resolveChatDisplay({ [ENVIRONMENT_PLACEMENT_KEY]: "center" }).environmentPlacement).toBe("left");
  });
});

describe("chat display drawing", () => {
  test("a bigger font sets the variables and the estimator's line together", () => {
    const display = resolveChatDisplay({ "agentPane.display.font.size": 16, "agentPane.display.font.lineHeight": 1.5 });
    const variables = chatDisplayVariables(display);
    expect(variables["--cv-font-size"]).toBe("16px");
    expect(variables["--cv-line-height"]).toBe("24px");
    expect(chatMetrics(display).lineHeight).toBe(24);
    expect(chatMetrics(display).measureFont).toBe('16px "Inter", system-ui, sans-serif');
    // Code keeps its share of the text: 13/14 inline and 12/14 in blocks.
    expect(chatMetrics(display).blockCodeSize).toBeCloseTo((12 * 16) / 14, 2);
  });

  test("a code font goes in front of the terminal font; code size follows the code scale", () => {
    const display = resolveChatDisplay({
      "agentPane.display.code.family": "JetBrains Mono",
      "agentPane.display.code.scale": 1,
    });
    const variables = chatDisplayVariables(display);
    expect(variables["--cv-mono"]).toBe('"JetBrains Mono", var(--cv-mono-default)');
    expect(variables["--cv-codeblock-size"]).toBe("14px");
    expect(variables["--cv-code-size"]).toBe("14px");
  });

  test("applying sets and clears the root's variables", () => {
    const style = new Map<string, string>();
    const root = {
      style: {
        setProperty: (name: string, value: string) => void style.set(name, value),
        removeProperty: (name: string) => void style.delete(name),
      },
    } as unknown as HTMLElement;
    applyChatDisplay(root, resolveChatDisplay({ "agentPane.display.font.size": 18 }));
    expect(style.get("--cv-font-size")).toBe("18px");
    applyChatDisplay(root, resolveChatDisplay({}));
    expect(style.has("--cv-font-size")).toBe(false);
  });

  test("the user's width replaces the column trial; Full Width fills the pane", () => {
    const wide = resolveChatDisplay({ "agentPane.display.width": 1200 });
    expect(chatColumnOf("standard", wide, 1.25).max).toBe(960);
    expect(chatDisplayVariables(wide)["--cv-column"]).toBe(
      "clamp(calc(720px / var(--cmux-ui-scale, 1)), 100%, calc(1200px / var(--cmux-ui-scale, 1)))",
    );
    const full = resolveChatDisplay({ "agentPane.display.fullWidth": true });
    expect(chatColumnOf("wide", full).max).toBe(Infinity);
    expect(chatDisplayVariables(full)["--cv-column"]).toBe("100%");
    // No width of the user's own: the Debug Settings trial still picks the column.
    expect(chatColumnOf("wide", resolveChatDisplay({})).max).toBe(960);
  });

  // https://github.com/manaflow-ai/cmux/issues/31510: out of the box the column sat at 720px on
  // any pane under 1280px while Settings said Chat Text Width 800, and 810 jumped to 810px.
  test("the default column is the one Chat Text Width 800 promises", () => {
    const defaults = chatColumnOf("standard", resolveChatDisplay({}));
    const near = (width: number) => chatColumnOf("standard", resolveChatDisplay({ "agentPane.display.width": width }));
    for (const pane of [760, 900, 1000, 1200, 1600]) {
      const at = transcriptColumn(pane, defaults).width;
      expect({ pane, width: at }).toEqual({ pane, width: transcriptColumn(pane, near(800)).width });
      expect(at).toBeLessThanOrEqual(transcriptColumn(pane, near(810)).width);
      expect(at).toBeGreaterThanOrEqual(transcriptColumn(pane, near(790)).width);
    }
    expect(transcriptColumn(1000, defaults).width).toBe(800);
  });
});
