// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". The
// Artifacts page's signed-out failure ("Sign in to cmux to see your artifacts.") shows the shared Sign
// In button, which runs the app's Sign In action; any other failure keeps only Try Again.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";

const scope = globalThis as Record<string, unknown>;
// The page's file tree (@pierre/trees) defines a custom element when it loads.
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLTemplateElement",
  "customElements",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    HTMLTemplateElement: window.HTMLTemplateElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** A host whose every read fails with `code`, recording each call. */
function failingHost(code: string) {
  const calls: { op: string; params: unknown }[] = [];
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      if (op === "cmux.app.action.run") return { ran: true } as R;
      throw pageError(code, "Sign in to cmux to see your artifacts.", true);
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  return { client, calls };
}

async function render(code: string) {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactsPage } = await import("../src/pages/artifacts/ArtifactsPage");
  const { ArtifactsStore } = await import("../src/pages/artifacts/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/artifacts/generated/strings.json")).default;
  const fake = failingHost(code);
  const store = new ArtifactsStore(fake.client);
  await store.start();
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ArtifactsPage store={store} strings={createStrings(table, ["en"])} />));
  return fake;
}

test("signed out, the page offers Sign In, which runs the app's Sign In action", async () => {
  const fake = await render("cmux.artifacts.signed_out");
  const button = host.querySelector<HTMLButtonElement>('[data-action="sign-in"]');
  expect(button?.textContent).toBe("Sign In");
  await act(async () => button!.click());
  expect(fake.calls.at(-1)).toEqual({ op: "cmux.app.action.run", params: { action: "palette.auth.signIn" } });
});

test("another failure offers no Sign In", async () => {
  await render("cmux.artifacts.failed");
  expect(host.querySelector('[data-action="sign-in"]')).toBeNull();
  expect(host.querySelector(".artifacts-retry")).not.toBeNull();
});
