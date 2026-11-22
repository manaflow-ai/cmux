// Make cmux Yours (cmux#48416): the first run's one setup screen. Drawn as a person reads it, and
// each pick sent to the host as the op it owns.
import { afterAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { makeItYoursState } from "./fixtures";
import table from "./generated/strings.json";
import type { MakeItYoursLook } from "./MakeItYoursStep";
import { OnboardingPage } from "./Onboarding";
import { OPS, type OnboardingState } from "./ops";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(restore);

const strings = createStrings(table, ["en"]);

function render(state: OnboardingState, look?: MakeItYoursLook): string {
  const store = new OnboardingStore(null, state);
  return renderToStaticMarkup(<OnboardingPage store={store} strings={strings} makeItYoursLook={look} />);
}

const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

/** The checked value of each radio group, read from the page as a browser shows it. */
async function checked(state: OnboardingState): Promise<Record<string, string>> {
  const root = document.createElement("div");
  document.body.append(root);
  const page = createRoot(root);
  await act(async () => page.render(<OnboardingPage store={new OnboardingStore(null, state)} strings={strings} />));
  const radios = [...root.querySelectorAll<HTMLInputElement>('input[type="radio"]')].filter((input) => input.checked);
  const values = Object.fromEntries(radios.map((input) => [input.name, input.value]));
  // One per group: a second checked radio in a group would overwrite its value above.
  expect(radios.length).toBe(Object.keys(values).length);
  await act(async () => page.unmount());
  root.remove();
  return values;
}

describe("make cmux yours", () => {
  test("a fresh person sees the three choices on the recommended answers, and Skip / Continue", async () => {
    const html = render(makeItYoursState("fresh"));
    const words = text(html);
    for (const key of [
      "onboarding.makeItYours.title",
      "onboarding.makeItYours.work.gui",
      "onboarding.makeItYours.work.terminal",
      "onboarding.makeItYours.recommended",
      "onboarding.makeItYours.density.standard",
      "onboarding.makeItYours.background.none",
      "onboarding.makeItYours.background.shuffle",
    ])
      expect(words).toContain(strings.t(key));
    expect(words).toContain("Continue");
    expect(words).not.toContain("lassic");
    // One checked radio per group: GUI-first, Standard, no background.
    expect(await checked(makeItYoursState("fresh"))).toEqual({ workStyle: "gui", density: "standard", background: "" });
  });

  test("the settings a person already has are what is checked", async () => {
    expect(await checked(makeItYoursState("picked"))).toEqual({
      workStyle: "gui",
      density: "compact",
      background: "friedrich-forest-moonlight",
    });
    expect((await checked(makeItYoursState("terminal"))).workStyle).toBe("terminal");
  });

  test("both looks draw every choice; only cards name the background tiles", () => {
    const cards = render(makeItYoursState("fresh"), "cards");
    const rows = render(makeItYoursState("fresh"), "rows");
    for (const html of [cards, rows]) expect(html.match(/type="radio"/g)?.length).toBe(2 + 3 + 6);
    expect(cards).toContain("onb-make-tile-name");
    expect(rows).not.toContain("onb-make-tile-name");
  });

  test("while the previews load only None is offered", () => {
    expect(render(makeItYoursState("loading")).match(/name="background"/g)?.length).toBe(1);
  });

  test("each pick is sent as its op; None sends a null id", async () => {
    const calls: { op: string; params: unknown }[] = [];
    const client = {
      call: async (op: string, params: unknown) => {
        calls.push({ op, params });
        return {} as never;
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    };
    const store = new OnboardingStore(client, makeItYoursState("picked"));
    const root = document.createElement("div");
    document.body.append(root);
    await act(async () => createRoot(root).render(<OnboardingPage store={store} strings={strings} />));
    calls.length = 0;
    const radio = (name: string, value: string) =>
      root.querySelector<HTMLInputElement>(`input[name="${name}"][value="${value}"]`)!;
    await act(async () => radio("workStyle", "terminal").click());
    await act(async () => radio("density", "comfortable").click());
    await act(async () => radio("background", "").click());
    expect(calls).toEqual([
      { op: OPS.workStyle, params: { value: "terminal" } },
      { op: OPS.density, params: { value: "comfortable" } },
      { op: OPS.background, params: { id: null } },
    ]);
  });
});
