// A send too large for one acpmux message waits for its images' originals still uploading
// (promptBudget.ts). A later send that goes (it fits once some images were removed) ends that
// wait: the held send must never go later on its own with whatever draft is in the composer then.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useSendWhenOriginals } from "./attachmentIntake";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

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
});

async function mount() {
  root = createRoot(installDom());
  let hold!: ReturnType<typeof useSendWhenOriginals>;
  function Probe({ uploading }: { uploading: number }) {
    hold = useSendWhenOriginals(uploading, "chat");
    return null;
  }
  const render = (uploading: number) => act(async () => root!.render(<Probe uploading={uploading} />));
  await render(2);
  return { render, hold: (awaits: boolean, send: () => void) => hold(awaits, send) };
}

test("a send over the budget goes once the originals it waits for are saved", async () => {
  const probe = await mount();
  let sent = 0;
  expect(probe.hold(true, () => (sent += 1))).toBe(true);
  await probe.render(1);
  expect(sent).toBe(0);
  await probe.render(0);
  expect(sent).toBe(1);
});

test("a later send that goes ends the wait: the held one never goes on its own", async () => {
  const probe = await mount();
  let held = 0;
  expect(probe.hold(true, () => (held += 1))).toBe(true);
  // The person took out images until the prompt fits, and sent it: it goes now.
  expect(probe.hold(false, () => undefined)).toBe(false);
  // The originals finish (or their chips leave with the sent prompt): nothing else goes.
  await probe.render(0);
  expect(held).toBe(0);
});
