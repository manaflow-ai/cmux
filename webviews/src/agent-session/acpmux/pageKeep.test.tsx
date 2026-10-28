// The agent page's own keep reasons: an unsent prompt holds `draft` and dictation
// holds `capture`, each sent once when it starts and once when it ends, never per keystroke; the
// prompt's send or clear also ends the page's automatic edits (pageEdits.ts).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { KEEP_ALIVE_OP, PageKeepAlive, type PageClient } from "../../pages/shared/pageClient";
import { usePageDraft, usePageKeepReason } from "./pageKeep";

type Sent = { reason: string; on: boolean };

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function recording() {
  const sent: Sent[] = [];
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      if (op === KEEP_ALIVE_OP) sent.push(params as Sent);
      return {} as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const keep = new PageKeepAlive(client);
  return { keep, sent, alive: () => keep };
}

async function mount(element: React.ReactElement): Promise<(next: React.ReactElement) => Promise<void>> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(element);
  });
  return async (next) => {
    await act(async () => {
      root!.render(next);
    });
  };
}

function Draft({ text, alive }: { text: string; alive: () => PageKeepAlive }) {
  usePageDraft(text.trim() !== "", alive);
  return null;
}

function Capture({ on, alive }: { on: boolean; alive: () => PageKeepAlive }) {
  usePageKeepReason("capture", on, alive);
  return null;
}

test("an unsent prompt holds draft once; its send ends draft and the page's edits", async () => {
  const { keep, sent, alive } = recording();
  const render = await mount(<Draft text="" alive={alive} />);
  expect(sent).toEqual([]);
  keep.set("user_edits", true, {}); // the page's automatic edits heard the first key
  for (const text of ["h", "he", "hel", "hello"]) await render(<Draft text={text} alive={alive} />);
  await render(<Draft text="" alive={alive} />);
  expect(sent).toEqual([
    { reason: "user_edits", on: true },
    { reason: "draft", on: true },
    { reason: "draft", on: false },
    { reason: "user_edits", on: false },
  ]);
});

test("an empty prompt never ends the page's edits", async () => {
  const { keep, sent, alive } = recording();
  const render = await mount(<Draft text="" alive={alive} />);
  keep.set("user_edits", true, {});
  await render(<Draft text=" " alive={alive} />);
  expect(sent).toEqual([{ reason: "user_edits", on: true }]);
});

test("dictation holds capture while it runs and its unmount ends it", async () => {
  const { sent, alive } = recording();
  const render = await mount(<Capture on={false} alive={alive} />);
  await render(<Capture on alive={alive} />);
  await render(<Capture on alive={alive} />);
  await render(<Capture on={false} alive={alive} />);
  await render(<Capture on alive={alive} />);
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  expect(sent).toEqual([
    { reason: "capture", on: true },
    { reason: "capture", on: false },
    { reason: "capture", on: true },
    { reason: "capture", on: false },
  ]);
});
