// Leo 2026-10-21: a new chat read "Thinking" forever while the agent waited on the folder's trust
// question, so he waited on an agent that waited on him. While an ask above the composer waits on
// the person, the running turn's line says so: never "Thinking", never a ticking "Working for".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { Thinking } from "./Thinking";
import { WaitingOnContext, type WaitingOn, waitingOn } from "./waitingOn";
import { WorkingFor } from "./WorkingFor";

const cwd = "/Users/you/Projects/demo-app";
const none = { permission: false, secret: false, question: false };

function within(waiting: WaitingOn | undefined, line: React.ReactElement) {
  return renderToStaticMarkup(<WaitingOnContext.Provider value={waiting}>{line}</WaitingOnContext.Provider>);
}

test("a pending trust question never renders as thinking", () => {
  const waiting = waitingOn({ ...none, trust: { cwd, state: "ask" } });
  expect(waiting).toBe("trust");
  const html = within(waiting, <Thinking />);
  expect(html).toContain(translate("turn.waiting.trust"));
  expect(html).not.toContain(`>${translate("thinking")}<`);
  // The start status ("Starting Claude Code…") gives way too: the prompt waits on the person.
  const starting = within(waiting, <Thinking status="Starting Claude Code…" />);
  expect(starting).toContain(translate("turn.waiting.trust"));
  expect(starting).not.toContain("Starting Claude Code…");
});

test("a running turn that waits on a permission shows no clock", () => {
  const row = { id: "working-1", version: 1, at: 0, kind: "working", doing: "Bash" } as AcpmuxRow;
  const html = within("permission", <WorkingFor row={row} now={() => 125_000} />);
  expect(html).toContain(translate("turn.waiting.permission"));
  expect(html).not.toContain("2m");
  expect(html).not.toContain("Bash");
  // Without a wait the same line ticks and names the call, as before.
  const running = within(undefined, <WorkingFor row={row} now={() => 125_000} />);
  expect(running).toContain("Bash");
  expect(running).not.toContain(translate("turn.waiting.permission"));
});

test("the trust question comes first, then the other asks in the stack's order", () => {
  expect(waitingOn({ ...none, trust: { cwd, state: "failed" }, permission: true })).toBe("trust");
  expect(waitingOn({ ...none, trust: { cwd, state: "remote" } })).toBe("trustRemote");
  // An answered folder waits on nobody, and a decided Don't trust runs no turn to wait in.
  expect(waitingOn({ ...none, trust: { cwd, state: "decided", level: "trusted" } })).toBeUndefined();
  expect(waitingOn({ ...none, trust: { cwd, state: "decided", level: "untrusted" } })).toBeUndefined();
  expect(waitingOn({ ...none, permission: true, secret: true })).toBe("permission");
  expect(waitingOn({ ...none, secret: true, question: true })).toBe("secret");
  expect(waitingOn({ ...none, question: true })).toBe("question");
  expect(waitingOn(none)).toBeUndefined();
});
