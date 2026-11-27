import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { importState } from "./fixtures";
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

async function mount() {
  const { calls, client } = recording();
  const state = importState("ready");
  const store = new OnboardingStore(client, state);
  const root = document.createElement("div");
  document.body.append(root);
  await act(async () =>
    createRoot(root).render(<OnboardingPage store={store} strings={createStrings(table, ["en"])} />),
  );
  // Express shows the summary first; the rows live behind Choose Browsers and Data….
  const choose = [...root.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent?.trim() === createStrings(table, ["en"]).t("onboarding.import.express.choose"),
  );
  if (choose) await act(async () => choose.click());
  const profile = state.importer!.rows.find((row) => row.kind === "profile" && row.checked && !row.needsFullDiskAccess);
  const row = root.querySelector<HTMLElement>(`[data-row="${profile!.kind === "profile" ? profile!.id : ""}"]`)!;
  calls.length = 0;
  return { calls, row };
}

test("opening a row's target menu does not toggle the profile", async () => {
  const { calls, row } = await mount();
  const target = row.querySelector<HTMLElement>(".onb-import-target button, .onb-import-target [role='combobox']");
  expect(target).not.toBeNull();
  await act(async () => target!.click());
  expect(calls.filter((call) => call.op === OPS.toggleProfile)).toEqual([]);
});

test("the checkbox toggles once, and a click on the row's surface toggles once", async () => {
  const { calls, row } = await mount();
  await act(async () => row.querySelector<HTMLInputElement>("input[type=checkbox]")!.click());
  expect(calls.filter((call) => call.op === OPS.toggleProfile).length).toBe(1);
  await act(async () => row.querySelector<HTMLElement>(".onb-import-name")!.click());
  expect(calls.filter((call) => call.op === OPS.toggleProfile).length).toBe(2);
});
