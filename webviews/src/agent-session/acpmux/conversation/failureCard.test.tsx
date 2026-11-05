// l10n-allow-file: test fixture prompts and errors, not shipped UI.
// A failed turn's card in the transcript (TurnRows.tsx TurnFailure), cmux#36329: it stayed in the chat
// after the error resolved and had no way to put it away. Once a later turn ends well the card clears
// on its own, and while it shows its × puts it away; the turn's footer keeps its Retry.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { TurnFooter } from "./TurnRows";
import { lastCompletedAt, turnView } from "./turns";
import { ResolvedBeforeContext, TurnActionsContext, type TurnActions } from "./turnActions";

const P = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
const A = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const done = (id: string, at: number): AcpmuxRow => ({ id, version: 1, at, kind: "turnSummary", status: "completed" });
const failed = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "turnSummary",
  status: "failed",
  error: "Can't reach the model: connection reset",
});

const actions: TurnActions = { retry: () => undefined };

/// Each drawn footer's id, and whether it draws the failure card.
function cards(source: AcpmuxRow[]): Record<string, boolean> {
  const rows = turnView(source, new Set(), { now: 1_000 });
  const resolvedBefore = lastCompletedAt(rows);
  const out: Record<string, boolean> = {};
  for (const row of rows) {
    if (row.kind !== "turnSummary") continue;
    const markup = renderToStaticMarkup(
      <TurnActionsContext.Provider value={actions}>
        <ResolvedBeforeContext.Provider value={resolvedBefore}>
          <TurnFooter row={row} />
        </ResolvedBeforeContext.Provider>
      </TurnActionsContext.Provider>,
    );
    out[row.id] = markup.includes("cv-turn-error");
  }
  return out;
}

test("a failed turn keeps its card while it is the chat's last word", () => {
  expect(cards([P("p1", 10, "Fix the grid"), failed("s1", 20)])).toEqual({ s1: true });
  // A turn that ended well before it does not resolve it.
  expect(
    cards([P("p0", 1, "Hi"), A("a0", 2, "Hello."), done("s0", 3), P("p1", 10, "Fix the grid"), failed("s1", 20)]),
  ).toEqual({ s0: false, s1: true });
});

test("a failed turn's card clears once a later turn ends well", () => {
  expect(
    cards([
      P("p1", 10, "Fix the grid"),
      failed("s1", 20),
      P("p2", 30, "Try again"),
      A("a2", 40, "Fixed."),
      done("s2", 50),
    ]),
  ).toEqual({ s1: false, s2: false });
  // A later turn that failed too keeps both cards: nothing resolved them.
  expect(cards([P("p1", 10, "Fix the grid"), failed("s1", 20), P("p2", 30, "Try again"), failed("s2", 40)])).toEqual({
    s1: true,
    s2: true,
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  resetTranscriptDisclosure();
});

test("a failed turn's × puts its card away, and it stays away when the row is drawn again", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  const row: AcpmuxRow = { ...failed("s1", 20), retryable: true, prompt: "Fix the grid", retryRowId: "p1" };
  const draw = (mounted: boolean) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <TranscriptDisclosureProvider sessionId="chat-36329">
          <TurnActionsContext.Provider value={actions}>
            {mounted && <TurnFooter row={row} />}
          </TurnActionsContext.Provider>
        </TranscriptDisclosureProvider>,
      );
    });
  await draw(true);
  expect(container.querySelector(".cv-turn-error")).not.toBeNull();
  const dismiss = container.querySelector<HTMLButtonElement>('.cv-turn-error [data-notice-action="dismiss"]');
  expect(dismiss).not.toBeNull();
  await act(async () => {
    dismiss!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(container.querySelector(".cv-turn-error")).toBeNull();
  // The footer stays, with the last turn's Retry.
  expect(container.querySelector('[aria-label="Retry"]')).not.toBeNull();
  // Scrolled out and back (the transcript is virtualized): still put away.
  await draw(false);
  await draw(true);
  expect(container.querySelector(".cv-turn-error")).toBeNull();
});
