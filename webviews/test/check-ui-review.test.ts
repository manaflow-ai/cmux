import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import {
  findHardCodedAgentIcons,
  findMixedRowWeights,
  findMultiSpace,
  findNarration,
  findRedundantOpenButtons,
  findRepeatedLeadingLabels,
  loadAllowlist,
  WEBVIEWS,
} from "../scripts/check-ui-review";

const tsx = join(WEBVIEWS, "src/fixture.tsx");
const css = join(WEBVIEWS, "src/fixture.css");

describe("cross-surface UI review lint", () => {
  test("flags narration in translated and visible copy", () => {
    const source = `<div>{t("message.readAfterTurn")}</div>`;
    expect(findNarration(tsx, source, new Map([["message.readAfterTurn", "Read after this turn"]]))).toMatchObject([
      { rule: "narration", fingerprint: "Read after this turn", line: 1 },
    ]);
    expect(findNarration(tsx, "<span>Started sub-session child</span>")).toHaveLength(1);
  });

  test("flags an Open button nested in a clickable row", () => {
    const source = `<div onClick={open}><button>Open chat</button></div>`;
    expect(findRedundantOpenButtons(tsx, source)).toMatchObject([
      { rule: "redundant-open", fingerprint: "Open chat", line: 1 },
    ]);
    expect(findRedundantOpenButtons(tsx, `<div><button>Open chat</button></div>`)).toHaveLength(0);
  });

  test("flags alignment spaces in inline copy, while normal spacing passes", () => {
    expect(findMultiSpace(tsx, "<span>Ran      2 commands</span>")).toHaveLength(1);
    expect(findMultiSpace(tsx, "<span>Ran 2 commands</span>")).toHaveLength(0);
    expect(findMultiSpace(tsx, '<div aria-label="Ran      2 commands" />')).toHaveLength(1);
  });

  test("flags a repeated leading type label in mapped sibling rows", () => {
    const source = `<ul>{items.map((item) => <li><span>Subagent {item.name}</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, source)).toMatchObject([
      { rule: "repeated-leading-label", fingerprint: "subagent", line: 1 },
    ]);
    expect(
      findRepeatedLeadingLabels(tsx, `<ul>{items.map((item) => <li><Icon name=\"agent.session\" /></li>)}</ul>`),
    ).toHaveLength(0);
  });

  test("flags mixed weights in one statically grouped row kind", () => {
    const source = `.cv-subagent { font-weight: 400; } .cv-subagent__name { font-weight: 600; }`;
    expect(findMixedRowWeights(css, source)).toMatchObject([
      { rule: "mixed-row-weight", fingerprint: "cv-subagent|400,600" },
    ]);
    expect(
      findMixedRowWeights(css, `.cv-subagent { font-weight: 400; } .cv-subagent__name { font-weight: 400; }`),
    ).toHaveLength(0);
  });

  test("requires the harness icon component for agent rows, but permits its fallback", () => {
    const hardCoded = `<div className=\"cv-subagent\"><Icon name=\"agent.session\" /></div>`;
    expect(findHardCodedAgentIcons(tsx, hardCoded)).toMatchObject([
      { rule: "hard-coded-agent-icon", fingerprint: "cv-subagent|agent.session", line: 1 },
    ]);
    const harness = `<div className=\"cv-subagent\"><AgentMark agent={harness} fallback={<Icon name=\"agent.session\" />} /></div>`;
    expect(findHardCodedAgentIcons(tsx, harness)).toHaveLength(0);
  });

  test("keeps every existing exception owned and explained", () => {
    const entries = loadAllowlist();
    expect(entries.length).toBeGreaterThan(0);
    for (const entry of entries) {
      expect(entry.owner).toMatch(/\S+/);
      expect(entry.why).toMatch(/\S+/);
    }
  });
});
