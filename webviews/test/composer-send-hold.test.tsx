// A send and the files still coming (composer/attachmentIntake.tsx useSendWhenAttached). Leo,
// 2026-10-25: "...the composer should never ever freeze and prevent new things from happening".
// Review (Codex): a send made while files were still being read went the moment their uploads
// started, with none of them; it waits for them now. A send made once only uploads are left goes
// at once. (The composer counts uploads among the files a send waits for: composer-upload-first-send.)
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { useSendWhenAttached } from "../src/agent-session/acpmux/composer/attachmentIntake";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const { createRoot } = await import("react-dom/client");
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// Renders the hook with `loading` (files a send waits for) and `unsettled` (those plus uploads).
let hold: (send: () => void) => boolean = () => false;
let cancelHeld: () => void = () => {};
function Probe({ loading, unsettled }: { loading: number; unsettled: number }) {
  const pendingSend = useSendWhenAttached(loading, "chat", unsettled);
  hold = pendingSend;
  cancelHeld = pendingSend.cancel;
  return null;
}
const render = (loading: number, unsettled: number) =>
  act(() => root.render(<Probe loading={loading} unsettled={unsettled} />));

test("a send made while a file is read waits through its upload, then goes once", async () => {
  await render(1, 1);
  let sent = 0;
  expect(hold(() => (sent += 1))).toBe(true);
  // Its upload starts: the file is no longer read, but the send it was made with still waits.
  await render(0, 1);
  expect(sent).toBe(0);
  // The upload finished (its chip is staged): the send goes, once.
  await render(0, 0);
  expect(sent).toBe(1);
  await render(0, 0);
  expect(sent).toBe(1);
});

test("a send with nothing it waits for goes at once", async () => {
  await render(0, 2);
  expect(hold(() => {})).toBe(false);
});

test("while one send waits, a later one replaces it", async () => {
  await render(1, 1);
  const went: string[] = [];
  hold(() => went.push("first"));
  await render(0, 1);
  // Only uploads are left, but a send is waiting: this one waits in its place.
  expect(hold(() => went.push("second"))).toBe(true);
  await render(0, 0);
  expect(went).toEqual(["second"]);
});

test("an owned command cancels a held send before its attachments are removed", async () => {
  await render(1, 1);
  let sent = 0;
  expect(hold(() => (sent += 1))).toBe(true);
  cancelHeld();
  await render(0, 0);
  expect(sent).toBe(0);
  expect(hold(() => (sent += 1))).toBe(false);
  await render(1, 1);
  expect(hold(() => (sent += 1))).toBe(true);
  await render(0, 0);
  expect(sent).toBe(1);
});
