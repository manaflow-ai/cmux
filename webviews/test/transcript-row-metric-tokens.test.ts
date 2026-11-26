// The shared row metric has one source (rowMetric.ts ROW_METRIC): the stylesheet's tokens, the row
// estimates (model.ts) and the spacing spec (transcriptSpacing.ts) all read it, so no activity row
// kind can drift to a height, text size or chip of its own (Leo, 2026-11-17: "these are too big";
// the rows had grown apart because the 22px line was a literal in the CSS, another in model.ts and
// a third in each spacing value, and each row kind set the prose's font on its own).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { ROW_METRIC } from "../src/agent-session/acpmux/rowMetric";
import { ROW_AIR_LOOKS, TRANSCRIPT_LINE_ROW, TRANSCRIPT_LINE_WORDS } from "../src/agent-session/acpmux/transcriptGrid";
import { SYSTEM_ROW_PITCH, TRANSCRIPT_SPACING } from "../src/agent-session/acpmux/transcriptSpacing";

const ACPMUX = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const read = (file: string) => readFileSync(path.join(ACPMUX, file), "utf8");
/** The prose's size at the default reading size (chatDisplay.ts DEFAULT_CHAT_DISPLAY.fontSize). */
const PROSE = 14;

/** A custom property's value in the stylesheet's :root block. */
function token(css: string, name: string): string | undefined {
  const root = css.slice(css.indexOf(":root {"), css.indexOf("\n}", css.indexOf(":root {")));
  return new RegExp(`${name}:\\s*([^;]+);`).exec(root)?.[1]?.trim();
}

describe("the shared row metric", () => {
  const css = read("conversation/conversation.css");
  test("the stylesheet's row tokens are rowMetric.ts's", () => {
    expect({
      height: token(css, "--cv-tool-row-height"),
      air: token(css, "--cv-row-air"),
      font: token(css, "--cv-row-font-size"),
      chip: token(css, "--cv-row-chip-height"),
      glyph: token(css, "--cv-row-glyph"),
      ruleAbove: token(css, "--cv-worked-rule-above"),
      ruleBelow: token(css, "--cv-worked-rule-below"),
    }).toEqual({
      height: `calc(${TRANSCRIPT_LINE_WORDS}px + var(--cv-row-air))`,
      air: `${ROW_AIR_LOOKS.shipped}px`,
      font: `calc(var(--cv-font-size) * ${ROW_METRIC.font} / ${PROSE})`,
      chip: `${ROW_METRIC.chip}px`,
      glyph: `${ROW_METRIC.glyph}px`,
      ruleAbove: `${ROW_METRIC.ruleAbove}px`,
      ruleBelow: `${ROW_METRIC.ruleBelow}px`,
    });
  });
  test("the row estimates read the metric, never a literal", () => {
    const model = read("model.ts");
    expect(TRANSCRIPT_LINE_ROW).toBe(ROW_METRIC.height);
    expect(ROW_METRIC.height).toBe(TRANSCRIPT_LINE_WORDS + ROW_AIR_LOOKS.shipped);
    expect(model).toContain("let lineRowPt = TRANSCRIPT_LINE_ROW;");
    expect(model).toContain("const WORKED_GAP_PT = ROW_METRIC.ruleAbove + ROW_METRIC.ruleBelow;");
  });
  test("the spacing spec's one-line pitch is the metric's row", () => {
    expect(SYSTEM_ROW_PITCH).toBe(ROW_METRIC.height);
    expect(TRANSCRIPT_SPACING.find((row) => row.id === "step-pitch")?.value).toBe(ROW_METRIC.height);
  });
  test("every one-line row kind takes the row text size, not the prose's", () => {
    // The containers of the one-line rows: tool runs (.cv-tools), Worked for, received and sent
    // lines, a message group's head and the waiting group. Their opened bodies (Markdown, outputs)
    // set the prose's size themselves.
    const rules: [string, string][] = [
      ["conversation/conversation.css", ".cv-tools {"],
      ["conversation/conversation.css", ".cv-worked {"],
      ["conversation/conversation.css", ".cv-received {"],
      ["conversation/AgentMessageRow.css", ".cv-agentmsg {"],
      ["conversation/MessageGroupHead.css", ".cv-message-group__head {"],
      ["conversation/PendingMessagesCard.css", ".cv-pending {"],
    ];
    for (const [file, selector] of rules) {
      const sheet = read(file);
      const at = sheet.indexOf(`\n${selector}`);
      expect({ selector, found: at >= 0 }).toEqual({ selector, found: true });
      const block = sheet.slice(at, sheet.indexOf("\n}", at));
      expect({ selector, size: /font-size:\s*([^;]+);/.exec(block)?.[1] }).toEqual({
        selector,
        size: "var(--cv-row-font-size)",
      });
    }
  });
  test("a session chip is the metric's chip", () => {
    const tag = read("conversation/AgentTag.css");
    expect(tag).not.toContain("height: calc(1em");
    expect(tag.match(/height: var\(--cv-row-chip-height/g)?.length).toBe(4);
  });
});
