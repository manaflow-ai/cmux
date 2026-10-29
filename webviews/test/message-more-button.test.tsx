// Leo, 2026-10-22: "There's only the hover situation. I need to be able to see this, like on
// hover. ... every single message has that kind of thing where you can, like, do stuff to it."
// Every message's action row (a prompt's under its bubble, an answer's turn footer) has More (…),
// which opens the menu a right-click on that message opens: it sends the host the same report the
// right-click sends, plus the button's box to open the menu under (`popUp`).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MouseEvent: dom.window.MouseEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { installMessageMenuReporter, messageMenuTarget, setMessageMenuSource } =
  await import("../src/agent-session/acpmux/conversation/messageMenu");

const prompt: AcpmuxRow = { id: "prompt", version: 1, at: 1, kind: "user", text: "Make the chart" };
const answer: AcpmuxRow = { id: "answer", version: 1, at: 2, kind: "assistant", text: "Here is **the chart**." };
const summary: AcpmuxRow = { id: "summary-9", version: 1, at: 3, kind: "turnSummary", seq: 9, durationMs: 1_000 };
const snapshot = { rows: [prompt, answer, summary], connection: "connected" } as unknown as AcpmuxSnapshot;
// The footer as the transcript draws it (turns.ts): the answer's text, and the answer's row.
const footer: AcpmuxRow = { ...summary, text: answer.text, answerId: answer.id };

const doc = dom.window.document;
const reports: Record<string, unknown>[] = [];
installMessageMenuReporter(doc, () => ({ postMessage: (body) => reports.push(body as Record<string, unknown>) }));
setMessageMenuSource((rowId) => messageMenuTarget(snapshot, rowId));

const root = createRoot(doc.getElementById("root")!);
await act(async () =>
  root.render(
    <>
      <div data-row-id={prompt.id}>
        <UserBubble row={prompt} text={prompt.text!} />
      </div>
      <div data-row-id={answer.id}>
        <p className="cv-md">Here is the chart.</p>
      </div>
      <div data-row-id={footer.id}>
        <TurnFooter row={footer} />
      </div>
    </>,
  ),
);

const more = (row: string, actions: string) =>
  doc.querySelector<HTMLButtonElement>(`[data-row-id="${row}"] ${actions} button[aria-label="More"]`);
const press = async (button: HTMLButtonElement) => {
  await act(async () => button.click());
  return reports.at(-1);
};

test("a prompt's action row has no More button", async () => {
  const button = more(prompt.id, ".cv-user__actions");
  expect(button).toBeNull();
});

test("an answer's turn footer has More, which reports the answer as its right-click does", async () => {
  const button = more(footer.id, ".cv-turn-actions");
  expect(button).not.toBeNull();
  const report = (await press(button!))!;
  expect(report).toMatchObject({ text: "Here is the chart.", markdown: "Here is **the chart**." });
  const { popUp } = report;
  expect(popUp).toBeDefined();
});

test("a footer with no answer has no More", async () => {
  await act(async () => root.render(<TurnFooter row={summary} />));
  expect(doc.querySelector('button[aria-label="More"]')).toBeNull();
  await act(async () => root.unmount());
});
