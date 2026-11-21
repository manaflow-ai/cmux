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

describe("make cmux yours", () => {
  test("a fresh person sees the three choices on the recommended answers, and Skip / Continue", () => {
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
    // Exactly one checked radio per group: GUI-first, Standard, no background.
    expect(html).toMatch(/<input type="radio" name="workStyle" value="gui" checked=""/);
    expect(html).toMatch(/<input type="radio" name="density" value="standard" checked=""/);
    expect(html).toMatch(/<input type="radio" name="background" value="" aria-label="[^"]+" checked=""/);
    expect(html.match(/checked=""/g)?.length).toBe(3);
  });

  test("the settings a person already has are what is checked", () => {
    const html = render(makeItYoursState("picked"));
    expect(html).toMatch(/value="compact" checked=""/);
    expect(html).toMatch(/value="friedrich-forest-moonlight" aria-label="[^"]+" checked=""/);
    expect(render(makeItYoursState("terminal"))).toMatch(/value="terminal" checked=""/);
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
