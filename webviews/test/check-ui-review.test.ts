import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import {
  classifyFindings,
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
  test("each allowlist entry excuses one finding, so a second occurrence is new", () => {
    const finding = {
      rule: "repeated-leading-label" as const,
      file: "src/a.tsx",
      line: 1,
      fingerprint: "Agent",
      message: "",
    };
    const entry = { rule: finding.rule, file: finding.file, fingerprint: finding.fingerprint, owner: "o", why: "w" };
    const two = classifyFindings([finding, { ...finding, line: 9 }], [entry]);
    expect(two.newFindings.map((item) => item.line)).toEqual([9]);
    expect(two.staleAllowlist).toHaveLength(0);
    expect(classifyFindings([], [entry]).staleAllowlist).toEqual([entry]);
  });

  test("flags narration in translated and visible copy", () => {
    const source = `<div>{t("message.readAfterTurn")}</div>`;
    expect(findNarration(tsx, source, new Map([["message.readAfterTurn", "Read after this turn"]]))).toMatchObject([
      { rule: "narration", fingerprint: "Read after this turn", line: 1 },
    ]);
    expect(findNarration(tsx, "<span>Started sub-session child</span>")).toHaveLength(1);
  });

  test("reads only rendered expression values, not comparison operands", () => {
    const compared = `<div>{message === "Read after this turn" && <span>Queued</span>}</div>`;
    expect(findNarration(tsx, compared)).toHaveLength(0);
    expect(findNarration(tsx, `<div>{queued ? "Read after this turn" : null}</div>`)).toHaveLength(1);
    expect(findMultiSpace(tsx, `<div>{mode === "Ran  2" && <span>Queued</span>}</div>`)).toHaveLength(0);
  });

  test("flags an Open button nested in a clickable row", () => {
    const source = `<div onClick={open}><button>Open chat</button></div>`;
    expect(findRedundantOpenButtons(tsx, source)).toMatchObject([
      { rule: "redundant-open", fingerprint: "Open chat", line: 1 },
    ]);
    expect(findRedundantOpenButtons(tsx, `<div><button>Open chat</button></div>`)).toHaveLength(0);
    expect(findRedundantOpenButtons(tsx, `<div onClick={open}><button>Open</button></div>`)).toMatchObject([
      { fingerprint: "Open" },
    ]);
    expect(findRedundantOpenButtons(tsx, `<div onClick={open}><button>Opening soon</button></div>`)).toHaveLength(0);
  });

  test("an Open button with its own action inside a row that does something else passes", () => {
    const stops = `<div onClick={(event) => event.stopPropagation()}><button onClick={open}>Open</button></div>`;
    expect(findRedundantOpenButtons(tsx, stops)).toHaveLength(0);
    const same = `<div onClick={open}><button onClick={open}>Open</button></div>`;
    expect(findRedundantOpenButtons(tsx, same)).toMatchObject([{ fingerprint: "Open" }]);
  });

  test("a focusable row without a pointer action does not make its Open button redundant", () => {
    expect(findRedundantOpenButtons(tsx, `<div tabIndex={-1}><button>Open chat</button></div>`)).toHaveLength(0);
    expect(
      findRedundantOpenButtons(tsx, `<div role="listitem" onKeyDown={move}><button>Open chat</button></div>`),
    ).toHaveLength(0);
  });

  test("reads a styled button's rendered label, not its attributes", () => {
    const styled = `<div className="cv-row" onClick={open}><button type="button" className="cv-row__open">Open chat</button></div>`;
    expect(findRedundantOpenButtons(tsx, styled)).toMatchObject([
      { rule: "redundant-open", fingerprint: "Open chat", line: 1 },
    ]);
    const iconOnly = `<div onClick={open}><button type="button" aria-label="Open chat"><Icon name="arrow.right" /></button></div>`;
    expect(findRedundantOpenButtons(tsx, iconOnly)).toMatchObject([{ fingerprint: "Open chat" }]);
    const titled = `<div onClick={open}><button type="button" title="Open in new tab">Rename</button></div>`;
    expect(findRedundantOpenButtons(tsx, titled)).toHaveLength(0);
  });

  test("flags alignment spaces in inline copy, while normal spacing passes", () => {
    expect(findMultiSpace(tsx, "<span>Ran      2 commands</span>")).toHaveLength(1);
    expect(findMultiSpace(tsx, "<span>Ran 2 commands</span>")).toHaveLength(0);
    expect(findMultiSpace(tsx, '<div aria-label="Ran      2 commands" />')).toHaveLength(1);
    expect(findMultiSpace(tsx, '<div className="flex  gap-2" />')).toHaveLength(0);
    expect(findMultiSpace(tsx, '<div className={cx("flex  gap-2", open && "is-open")} />')).toHaveLength(0);
    expect(findMultiSpace(tsx, '<input placeholder={"Search  files"} />')).toHaveLength(1);
  });

  test("flags a repeated leading type label in mapped sibling rows", () => {
    const source = `<ul>{items.map((item) => <li><span>Subagent {item.name}</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, source)).toMatchObject([
      { rule: "repeated-leading-label", fingerprint: "subagent", line: 1 },
    ]);
    expect(
      findRepeatedLeadingLabels(tsx, `<ul>{items.map((item) => <li><Icon name="agent.session" /></li>)}</ul>`),
    ).toHaveLength(0);
  });

  test("reads a styled mapped row's rendered label, not its attributes", () => {
    const styled = `<ul>{items.map((item) => <li key={item.id} className="cv-row"><span className="cv-row__label">Subagent {item.name}</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, styled)).toMatchObject([
      { rule: "repeated-leading-label", fingerprint: "subagent", line: 1 },
    ]);
    const titled = `<ul>{items.map((item) => <li className="agent-row" title="Agent details"><span>{item.name}</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, titled)).toHaveLength(0);
    const compared = `<ul>{people.map((person) => <li className="lg-picker-row"><span>{person.name}</span>{person.kind === "agent" && <span>{t("agent.badge")}</span>}</li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, compared, new Map([["agent.badge", "Bot"]]))).toHaveLength(0);
    const unknownFirst = `<ul>{items.map((item) => <li>{item.name}<span>Agent</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, unknownFirst)).toHaveLength(0);
    const componentFirst = `<ul>{items.map((item) => <li><PersonName person={item} /><span>Agent</span></li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, componentFirst)).toHaveLength(0);
    const branch = `<ul>{items.map((item) => <li className="cv-row">{item.done ? "Task done" : t("row.pending")}</li>)}</ul>`;
    expect(findRepeatedLeadingLabels(tsx, branch)).toMatchObject([{ fingerprint: "task" }]);
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
    const hardCoded = `<div className="cv-subagent"><Icon name="agent.session" /></div>`;
    expect(findHardCodedAgentIcons(tsx, hardCoded)).toMatchObject([
      { rule: "hard-coded-agent-icon", fingerprint: "cv-subagent|agent.session", line: 1 },
    ]);
    const harness = `<div className="cv-subagent"><AgentMark agent={harness} fallback={<Icon name="agent.session" />} /></div>`;
    expect(findHardCodedAgentIcons(tsx, harness)).toHaveLength(0);
    const namespaced = `<div className="cv-subagent"><Icon ns:name="agent.session" /></div>`;
    expect(findHardCodedAgentIcons(tsx, namespaced)).toHaveLength(0);
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
