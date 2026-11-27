// Make cmux Yours with experiments.introWalk on: the intro walk's four screens (hq RFD 0057). Drawn as a
// person reads it, and each pick sent to the host as the op it owns. makeItYours.test.tsx covers the
// switch off: today's one screen, unchanged.
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
import { MAKE_IT_YOURS_SCREENS, type MakeItYoursScreen } from "./walk";

const restore = installDom();
afterAll(restore);

const strings = createStrings(table, ["en"]);
const WALK = { introWalk: true };

function renderScreen(state: OnboardingState, screen: MakeItYoursScreen, look?: MakeItYoursLook): string {
  const store = new OnboardingStore(null, state);
  return renderToStaticMarkup(
    <OnboardingPage store={store} strings={strings} makeItYoursLook={look} makeItYoursScreen={screen} />,
  );
}

/** Every screen of the walk, in order. */
function render(state: OnboardingState, look?: MakeItYoursLook): string {
  return MAKE_IT_YOURS_SCREENS.map((screen) => renderScreen(state, screen, look)).join("");
}

const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

/** The checked value of each radio group on every screen, read from the page as a browser shows it. */
async function checked(state: OnboardingState): Promise<Record<string, string>> {
  const values: Record<string, string> = {};
  for (const screen of MAKE_IT_YOURS_SCREENS) {
    const root = document.createElement("div");
    document.body.append(root);
    const page = createRoot(root);
    await act(async () =>
      page.render(
        <OnboardingPage store={new OnboardingStore(null, state)} strings={strings} makeItYoursScreen={screen} />,
      ),
    );
    const radios = [...root.querySelectorAll<HTMLInputElement>('input[type="radio"]')].filter((input) => input.checked);
    const found = Object.fromEntries(radios.map((input) => [input.name, input.value]));
    // One per group: a second checked radio in a group would overwrite its value above.
    expect(radios.length).toBe(Object.keys(found).length);
    Object.assign(values, found);
    await act(async () => page.unmount());
    root.remove();
  }
  return values;
}

describe("make cmux yours", () => {
  test("a fresh person walks four screens on the recommended answers, and Skip / Continue", async () => {
    const html = render(makeItYoursState("fresh", WALK));
    const words = text(html);
    for (const key of [
      "onboarding.makeItYours.title",
      "onboarding.makeItYours.work.gui",
      "onboarding.makeItYours.work.terminal",
      "onboarding.makeItYours.recommended",
      "onboarding.makeItYours.background.none",
    ])
      expect(words).toContain(strings.t(key));
    // The preview look (the default) names only the chosen work; each tile carries its name as its label.
    expect(html).toContain(`aria-label="${strings.t("onboarding.makeItYours.background.shuffle")}"`);
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
    expect(words).toContain("Continue");
    expect(words).not.toContain("lassic");
    // One checked radio per group: GUI-first, Default, no background; no material set.
    // The look screen first, its five tiles each with a light and a dark face.
    const look = renderScreen(makeItYoursState("fresh", WALK), "look");
    expect(look.match(/name="look"/g)?.length).toBe(5);
    expect(look.match(/data-face="light"/g)?.length).toBe(5);
    expect(look.match(/data-face="dark"/g)?.length).toBe(5);
    expect(look).not.toContain('name="density"');
    // Density is asked once, on Tune only.
    expect(render(makeItYoursState("fresh", WALK)).match(/name="density"/g)?.length).toBe(5);
    // One checked radio per group: House (what they have), GUI-first, Full Access, Banners and Sound,
    // Default, no background; no material set.
    expect(await checked(makeItYoursState("fresh", WALK))).toEqual({
      look: "house",
      workStyle: "gui",
      chatsRunIn: "local",
      chatFeel: "instant",
      permission: "fullAccess",
      computerUse: "fullAccess",
      noise: "bannersSound",
      density: "cozy",
      background: "",
    });
  });

  test("the settings a person already has are what is checked", async () => {
    expect(await checked(makeItYoursState("picked", WALK))).toEqual({
      look: "house",
      permission: "fullAccess",
      computerUse: "fullAccess",
      noise: "bannersSound",
      workStyle: "gui",
      chatsRunIn: "cloud",
      chatFeel: "instant",
      density: "compact",
      background: "dahl-dresden-moonlight",
      material: "frosted",
    });
    expect((await checked(makeItYoursState("terminal", WALK))).workStyle).toBe("terminal");
  });

  test("both looks draw every choice; only cards name the background tiles", () => {
    const cards = render(makeItYoursState("fresh", WALK), "cards");
    const rows = render(makeItYoursState("fresh", WALK), "rows");
    // Five looks, two ways to work, two places chats run, three chat feels, three permissions, five
    // Computer Use modes, three noises, five densities, None and eleven backgrounds, four materials.
    for (const html of [cards, rows])
      expect(html.match(/type="radio"/g)?.length).toBe(5 + 2 + 2 + 3 + 3 + 5 + 3 + 5 + 12 + 4);
    expect(cards).toContain("onb-make-tile-name");
    expect(rows).not.toContain("onb-make-tile-name");
  });

  test("while the previews load only None is offered", () => {
    expect(renderScreen(makeItYoursState("loading", WALK), "tune").match(/name="background"/g)?.length).toBe(1);
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
    const store = new OnboardingStore(client, makeItYoursState("picked", WALK));
    const root = document.createElement("div");
    document.body.append(root);
    let page2: ReturnType<typeof createRoot> | undefined;
    const page = createRoot(root);
    await act(async () => page.render(<OnboardingPage store={store} strings={strings} makeItYoursScreen="work" />));
    calls.length = 0;
    const radio = (name: string, value: string) =>
      root.querySelector<HTMLInputElement>(`input[name="${name}"][value="${value}"]`)!;
    await act(async () => radio("workStyle", "terminal").click());
    await act(async () => page.unmount());
    await act(async () =>
      (page2 = createRoot(root)).render(<OnboardingPage store={store} strings={strings} makeItYoursScreen="tune" />),
    );
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
    await act(async () => page2?.unmount());
    root.remove();
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
    const store = new OnboardingStore(client, makeItYoursState("picked", WALK));
    const root = document.createElement("div");
    document.body.append(root);
    await act(async () =>
      createRoot(root).render(<OnboardingPage store={store} strings={strings} makeItYoursScreen="tune" />),
    );
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
