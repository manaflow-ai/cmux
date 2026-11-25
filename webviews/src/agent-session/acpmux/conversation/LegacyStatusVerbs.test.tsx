// l10n-allow-file: synthetic verbs and tool labels for legacy transcript layouts.
import { expect, test } from "bun:test";
import type { ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { StatusVerbContext, type StatusVerbConfig } from "../statusVerbs";
import { ActivityLine } from "./ActivityLine";
import { WorkingFor } from "./WorkingFor";
import { WAITING_LABEL, WaitingOnContext, type WaitingOn } from "./waitingOn";

const row: AcpmuxRow = { id: "live", kind: "working", version: 1, at: 0, below: true, thinkingNow: true };
const custom: StatusVerbConfig = { mode: "custom", verbs: ["Planning", "Reading"] };
const layouts = [
  { name: "WorkingFor", render: (value: AcpmuxRow, now: number) => <WorkingFor row={value} now={() => now} /> },
  { name: "ActivityLine", render: (value: AcpmuxRow, now: number) => <ActivityLine row={value} now={() => now} /> },
];

function render(line: ReactElement, config: StatusVerbConfig = custom, waiting?: WaitingOn) {
  return renderToStaticMarkup(
    <StatusVerbContext.Provider value={config}>
      <WaitingOnContext.Provider value={waiting}>{line}</WaitingOnContext.Provider>
    </StatusVerbContext.Provider>,
  );
}

for (const layout of layouts) {
  test(`${layout.name} selects custom verbs from its existing elapsed clock`, () => {
    const first = render(layout.render(row, 0));
    const next = render(layout.render(row, 2_400));
    expect(first).toContain('class="cv-status-verb__word">Planning</span>');
    expect(next).toContain('class="cv-status-verb__word">Reading</span>');
    expect(next).toContain(`aria-label="${translate("thinking")}" aria-live="off"`);
    // Both labels reserve width, but sizing samples contain no text to copy or announce.
    expect(next).toContain('data-text="Planning" aria-hidden="true" inert=""');
    expect(next).toContain('data-text="Reading" aria-hidden="true" inert=""');
  });

  test(`${layout.name} honors Thinking only`, () => {
    const html = render(layout.render(row, 60_000), { mode: "thinking", verbs: ["Thinking"] });
    expect(html).toContain(`class="cv-status-verb__word">${translate("thinking")}</span>`);
    expect(html).not.toContain("Planning");
  });

  test(`${layout.name} keeps typed waits ahead of decorative verbs and time`, () => {
    const html = render(layout.render(row, 125_000), custom, "permission");
    expect(html).toContain('data-waiting="permission"');
    expect(html).toContain(translate(WAITING_LABEL.permission));
    expect(html).not.toContain("cv-status-verb");
    expect(html).not.toContain("2m");
  });

  test(`${layout.name} keeps real work and send labels`, () => {
    const work = { ...row, doing: "Run the checks", text: "Run the checks" };
    const html = render(layout.render(work, 2_400));
    expect(html).toContain("Run the checks");
    expect(html).not.toContain("cv-status-verb");
    const send = render(layout.render({ ...work, doingSendTo: "tests" }, 2_400));
    expect(send).toContain("Sending message to tests");
    expect(send).not.toContain("Run the checks");
    expect(send).not.toContain("cv-status-verb");
  });
}

test("WorkingFor keeps its held and generic work labels", () => {
  const held = render(<WorkingFor row={{ ...row, below: false, durationMs: 2_400 }} now={() => 60_000} />);
  expect(held).toContain(`>${translate("thinking")}<`);
  expect(held).toContain("2s");
  expect(held).not.toContain("cv-status-verb");
  const work = render(<WorkingFor row={{ ...row, thinkingNow: false }} now={() => 2_400} />);
  expect(work).not.toContain("cv-status-verb");
  expect(work).toContain("2s");
});
