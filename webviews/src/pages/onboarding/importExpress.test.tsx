// The import step's Express look (docs/design/onboarding-import-express.md): one summary with the
// checked browsers and one Import, the grant asks in plain sight, and the full list one click away.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { importState, type ImportFixture } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OPS } from "./ops";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(restore);
// The test DOM has no Web Animations; ViewSwap plays one when the body swaps (summary ⇄ list).
(window.HTMLElement.prototype as unknown as { animate: unknown }).animate ??= () => ({ cancel() {}, finish() {} });

const strings = createStrings(table, ["en"]);

/** A client that records each call (op and params) and answers nothing. */
function recording() {
  const calls: { op: string; params: unknown }[] = [];
  const client = {
    call: async (op: string, params: unknown) => {
      calls.push({ op, params });
      return {} as never;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  return { calls, client };
}

async function mount(fixture: ImportFixture = "ready") {
  const { calls, client } = recording();
  const state = importState(fixture);
  const store = new OnboardingStore(client, state);
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () => createRoot(root).render(<OnboardingPage store={store} strings={strings} />));
  calls.length = 0;
  return { calls, root };
}

const button = (root: HTMLElement, text: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((candidate) => candidate.textContent?.trim() === text);

test("ready shows one summary naming the checked browser, and no profile rows", async () => {
  const { root } = await mount();
  const summary = root.querySelector<HTMLElement>(".onb-express");
  expect(summary).not.toBeNull();
  // Northwind is the fixture's one checked browser; Meridian (Full Disk Access) is not checked.
  expect(summary!.querySelector(".onb-express-lead")!.textContent).toContain("Northwind");
  expect(summary!.querySelector(".onb-express-lead")!.textContent).not.toContain("Meridian");
  expect(root.querySelectorAll(".onb-import-row").length).toBe(0);
});

test("Choose Browsers and Data shows the full list, and Hide Details brings the summary back", async () => {
  const { root } = await mount();
  const choose = button(root, strings.t("onboarding.import.express.choose"));
  expect(choose).toBeDefined();
  await act(async () => choose!.click());
  expect(root.querySelectorAll(".onb-import-row[data-row]").length).toBeGreaterThan(0);
  const hide = button(root, strings.t("onboarding.import.express.hide"));
  expect(hide).toBeDefined();
  await act(async () => hide!.click());
  expect(root.querySelector(".onb-express")).not.toBeNull();
});

test("the grant asks sit in the summary and act once each", async () => {
  const { calls, root } = await mount();
  const asks = root.querySelector<HTMLElement>(".onb-express-asks")!;
  expect(asks).not.toBeNull();
  const fda = button(asks, strings.t("onboarding.button.openSystemSettings"));
  const folder = button(asks, strings.t("onboarding.access.allow"));
  expect(fda).toBeDefined();
  expect(folder).toBeDefined();
  await act(async () => fda!.click());
  await act(async () => folder!.click());
  expect(calls).toEqual([
    { op: OPS.openFullDiskAccess, params: {} },
    { op: OPS.askAccess, params: { browser: "orbit" } },
  ]);
});

test("importing names the profile being read in the summary", async () => {
  const { root } = await mount("importing");
  const lead = root.querySelector<HTMLElement>(".onb-express-lead");
  expect(lead).not.toBeNull();
  expect(lead!.textContent).toContain("Northwind");
  expect(root.querySelector(".onb-express .onb-progress")).not.toBeNull();
});
