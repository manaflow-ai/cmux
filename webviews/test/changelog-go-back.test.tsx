// Going back to an earlier build from the Updated card (GoBack.tsx). A go-back the person cancels at
// the quit dialog leaves cmux running: once the host stops saying it runs, the buttons work again
// (cmux#41013 review: every button stayed disabled on "going").
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const strings = { language: "en", t: (key: string) => key, format: (key: string) => key };
const goBack = { build: "90", label: "nightly 90 from Nov 10", kept: true, title: "Go Back to nightly 90 from Nov 10" };

test("a go-back that ends without a relaunch frees the buttons", async () => {
  const { createRoot } = await import("react-dom/client");
  const { GoBack } = await import("../src/pages/changelog/GoBack");
  // The host answers once the swap is done and the quit started: nil, the app is going away.
  const actions = { goBack: () => Promise.resolve(null) };
  const root = createRoot(host);
  const draw = (running: boolean) => <GoBack goBack={goBack} running={running} strings={strings} actions={actions} />;
  await act(async () => root.render(draw(false)));
  const entry = () => host.querySelector<HTMLButtonElement>(".wn-goback-entry")!;
  expect(entry().disabled).toBe(false);
  await act(async () => entry().click());
  expect(entry().disabled).toBe(true);
  await act(async () => root.render(draw(true)));
  expect(entry().disabled).toBe(true);
  // The quit was refused: the host's progress ends, and the page hears it.
  await act(async () => root.render(draw(false)));
  expect(entry().disabled).toBe(false);
  await act(async () => root.unmount());
});

test("a card opened while a go-back runs starts busy", async () => {
  const { createRoot } = await import("react-dom/client");
  const { GoBack } = await import("../src/pages/changelog/GoBack");
  const actions = { goBack: () => Promise.resolve(null) };
  const root = createRoot(host);
  await act(async () => root.render(<GoBack goBack={goBack} running strings={strings} actions={actions} />));
  expect(host.querySelector<HTMLButtonElement>(".wn-goback-entry")!.disabled).toBe(true);
  await act(async () => root.render(<GoBack goBack={goBack} running={false} strings={strings} actions={actions} />));
  expect(host.querySelector<HTMLButtonElement>(".wn-goback-entry")!.disabled).toBe(false);
  await act(async () => root.unmount());
});
