// Settings > Design System (RFD 0009 slice 8): the page draws the scene the CLI answers (the SDK's
// DesignSystemView of the resolved system, `cmux --json ext design --show --scene`), never a viewer
// of its own; roles cmux changed since the person's base are marked in it; a layer that did not
// read is listed under it; a host with no CLI says the system could not be read.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");
const { mockDesignSystem } = await import("./mockDesignSystem");
const { categories } = await import("./categories");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="designSystem"]');

async function open(setup?: (provider: MockSettingsProvider) => void) {
  page = await renderPage({ path: "/settings/designSystem", setup });
  await settle();
  return page;
}

test("Design System sits in Look and Feel after Tabs and Panes, and draws only its card", () => {
  const ids = categories.map((category) => category.id);
  expect(ids.indexOf("designSystem")).toBe(ids.indexOf("tabs") + 1);
  const category = categories.find((c) => c.id === "designSystem")!;
  expect(category.lead).toEqual(["designSystem"]);
  expect(category.groups).toEqual([]);
});

test("the page draws the CLI's scene: cmux's own system with nothing marked", async () => {
  await open();
  const text = card()!.textContent ?? "";
  for (const title of ["Type", "Spacing", "Limits"]) expect(text).toContain(title);
  expect(text).not.toContain("Changed in cmux");
  expect(card()!.querySelector(".cmux-app-scene-root")).not.toBeNull();
  expect(card()!.querySelector("[data-design-problems]")).toBeNull();
});

test("values cmux changed since the base are listed and marked in the scene", async () => {
  await open((provider) => {
    provider.designSystem = mockDesignSystem("changed");
  });
  const text = card()!.textContent ?? "";
  expect(text).toContain("Changed in cmux");
  expect(text).toContain("Built on cmux, then design.json");
  expect(text).toContain("type.numeral: cmux changed it from 32 pt semibold to 34 pt semibold");
  expect(text).toContain("cmux changed, yours holds");
});

test("a layer that did not read is listed under the viewer; no CLI says the system could not be read", async () => {
  await open((provider) => {
    provider.designSystem = mockDesignSystem("unreadable");
  });
  const problems = card()!.querySelector("[data-design-problems]");
  expect(problems?.textContent).toContain("theme dusk: type.body.size");
  page!.unmount();
  page = null;
  await open((provider) => {
    provider.designSystem = { scene: null } as never;
  });
  expect(card()?.textContent).toContain("The design system could not be read.");
});
