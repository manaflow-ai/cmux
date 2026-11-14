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

const strings = createStrings(table, ["en"]);

async function mount(fixture: ImportFixture = "ready") {
  const { calls, client } = recording();
  const state = importState(fixture);
  const store = new OnboardingStore(client, state);
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () => createRoot(root).render(<OnboardingPage store={store} strings={strings} />));
  // Express shows the summary first; the rows live behind Choose Browsers and Data….
  const choose = [...root.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent?.trim() === createStrings(table, ["en"]).t("onboarding.import.express.choose"),
  );
  if (choose) await act(async () => choose.click());
  calls.length = 0;
  return { calls, root, state };
}

test("a click anywhere on a Full Disk Access row opens System Settings", async () => {
  const { calls, root, state } = await mount();
  const blocked = state.importer!.rows.find((row) => row.kind === "profile" && row.needsFullDiskAccess);
  expect(blocked).toBeDefined();
  const row = root.querySelector<HTMLElement>(`[data-row="${blocked!.kind === "profile" ? blocked!.id : ""}"]`)!;
  await act(async () => row.querySelector<HTMLElement>(".onb-import-name")!.click());
  expect(calls.map((call) => call.op)).toEqual([OPS.openFullDiskAccess]);
});

test("the other sources sit in the footer, beside Skip and Import, and act once", async () => {
  const { calls, root } = await mount();
  const footer = root.querySelector<HTMLElement>(".onb-footer")!;
  const fromFiles = [...footer.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === strings.t("onboarding.import.fromFiles"),
  );
  expect(fromFiles).toBeDefined();
  await act(async () => fromFiles!.click());
  expect(calls.map((call) => call.op)).toEqual([OPS.fromFiles]);
});

test("the footer's other sources step aside while an explainer shows", async () => {
  const { root } = await mount("consent");
  const sources = root.querySelector<HTMLElement>(".onb-footer .onb-footer-sources");
  expect(sources == null || sources.hasAttribute("inert")).toBe(true);
});
