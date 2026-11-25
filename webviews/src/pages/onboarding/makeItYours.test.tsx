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
      "onboarding.makeItYours.background.none",
    ])
      expect(words).toContain(strings.t(key));
    // Every density Settings has, by Settings' names (cmux#49636).
    for (const name of ["Ultra-compact", "Compact", "Default", "Comfortable", "Spacious"])
      expect(words).toContain(name);
    // Settings' two rows for a background: Opacity and Material, with every material.
    for (const key of [
      "onboarding.makeItYours.opacity",
      "onboarding.makeItYours.material",
      "onboarding.makeItYours.material.none",
      "onboarding.makeItYours.material.frosted",
      "onboarding.makeItYours.material.glass",
      "onboarding.makeItYours.material.glass-clear",
    ])
      expect(words).toContain(strings.t(key));
    // The tiles are pictures: each is named by its radio (and the chosen one under the window).
    expect(html).toContain(`aria-label="${strings.t("onboarding.makeItYours.background.shuffle")}"`);
    expect(words).toContain("Continue");
    expect(words).not.toContain("lassic");
    // One checked radio per group: GUI-first, Default, no background; no material set.
    expect(await checked(makeItYoursState("fresh"))).toEqual({
      workStyle: "gui",
      density: "cozy",
      background: "",
    });
  });

  test("the settings a person already has are what is checked", async () => {
    expect(await checked(makeItYoursState("picked"))).toEqual({
      workStyle: "gui",
      density: "compact",
      background: "dahl-dresden-moonlight",
      material: "frosted",
    });
    expect((await checked(makeItYoursState("terminal"))).workStyle).toBe("terminal");
  });

  test("every look draws every choice; the default draws the window from the answers", () => {
    // Two ways to work, five densities, None and eleven backgrounds, four materials.
    for (const look of ["preview", "segmented", "form", "cards", "rows"] as const)
      expect(render(makeItYoursState("picked"), look).match(/type="radio"/g)?.length).toBe(2 + 5 + 12 + 4);
    expect(render(makeItYoursState("picked"), "cards")).toContain("onb-make-tile-name");
    expect(render(makeItYoursState("picked"), "rows")).not.toContain("onb-make-tile-name");
    const preview = render(makeItYoursState("picked"));
    expect(preview).toContain('data-look="preview"');
    expect(preview).toContain('data-density="compact"');
    expect(preview).toContain('data-work="gui"');
    expect(preview).toContain("onb-make-pane-chat");
    // The chosen work is named once, whole, under the window.
    expect(text(preview)).toContain("View of Dresden by Moonlight");
    const terminal = render(makeItYoursState("terminal"));
    expect(terminal).toContain("onb-make-pane-term");
    expect(terminal).not.toContain("onb-make-pane-chat");
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
    await act(async () => radio("density", "ultraCompact").click());
    await act(async () => radio("density", "spacious").click());
    await act(async () => radio("background", "").click());
    await act(async () => radio("background", "hokusai-great-wave").click());
    await act(async () => radio("material", "glass-clear").click());
    expect(calls).toEqual([
      { op: OPS.workStyle, params: { value: "terminal" } },
      { op: OPS.density, params: { value: "comfortable" } },
      { op: OPS.density, params: { value: "ultraCompact" } },
      { op: OPS.density, params: { value: "spacious" } },
      { op: OPS.background, params: { id: null } },
      { op: OPS.background, params: { id: "hokusai-great-wave" } },
      { op: OPS.material, params: { value: "glass-clear" } },
    ]);
  });

  test("Opacity: a key step is written at once; a drag is written once, on release", async () => {
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
    const slider = root.querySelector<HTMLInputElement>('input[type="range"]')!;
    expect(slider.value).toBe("0.6");
    expect(root.textContent).toContain("60%");
    const setValue = (value: string) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(slider, value);
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    };
    // A key: no pointer down first.
    await act(async () => setValue("0.65"));
    expect(calls).toEqual([{ op: OPS.opacity, params: { value: 0.65 } }]);
    calls.length = 0;
    // A drag: the slider follows, and one write lands when the pointer is let go.
    await act(async () => slider.dispatchEvent(new Event("pointerdown", { bubbles: true })));
    await act(async () => setValue("0.3"));
    await act(async () => setValue("0.2"));
    expect(calls).toEqual([]);
    expect(root.textContent).toContain("20%");
    await act(async () => slider.dispatchEvent(new Event("pointerup", { bubbles: true })));
    expect(calls).toEqual([{ op: OPS.opacity, params: { value: 0.2 } }]);
  });
});
