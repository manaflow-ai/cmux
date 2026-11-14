// Settings > Extensions: each installed extension's own settings, drawn from the schema the daemon
// answers (`apps.settings.list`): a switch, a choice, a text field and a number field. A change goes
// to the daemon (`apps.settings.set`), and the row shows the value the daemon answered; Reset to
// Default sends `null`; a value the manifest refuses shows the daemon's reason and changes nothing.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { readExtensionSettings } from "./extensionSettings";
import { readFileSync } from "node:fs";
import { hasIcon } from "./icons";

const restore = installDom();
afterAll(() => restore());
const { renderCard, changeValue, click, fire, ops } = await import("./testing");
const { ExtensionsCard } = await import("./components/ExtensionsCard");
const { categories, CATEGORY_CARDS } = await import("./categories");

const row = (container: HTMLElement, key: string) =>
  container.querySelector<HTMLElement>(`[data-extension="acme/standup"] [data-extension-setting="${key}"]`)!;
const sets = (provider: Parameters<typeof ops>[0]) => ops(provider, "cmux.settings.extensions.set");

test("each extension is a group with one row per declared setting, showing the values it runs with", async () => {
  const page = await renderCard(<ExtensionsCard />);
  const group = page.container.querySelector<HTMLElement>('[data-extension="acme/standup"]')!;
  expect(group.querySelector(".group-title")!.textContent).toBe("Standup Notes");
  expect(row(page.container, "greeting").textContent).toContain("The first line of each note.");
  expect(row(page.container, "greeting").querySelector<HTMLInputElement>("input")!.value).toBe("Morning!");
  expect(row(page.container, "compact").querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("false");
  expect(row(page.container, "size").querySelector<HTMLSelectElement>("select")!.value).toBe("small");
  expect(row(page.container, "limit").querySelector<HTMLInputElement>("input")!.value).toBe("10");
  expect(sets(page.provider)).toEqual([]);
  page.unmount();
});

test("a change goes to the daemon and the row shows the value it answered", async () => {
  const page = await renderCard(<ExtensionsCard />);
  await click(row(page.container, "compact").querySelector('[role="switch"]')!);
  expect(sets(page.provider)).toEqual([{ app: "acme/standup", values: { compact: true } }]);
  expect(row(page.container, "compact").querySelector('[role="switch"]')!.getAttribute("aria-checked")).toBe("true");

  await changeValue(row(page.container, "size").querySelector<HTMLSelectElement>("select")!, "large");
  const greeting = row(page.container, "greeting").querySelector<HTMLInputElement>("input")!;
  await changeValue(greeting, "Hi team");
  await fire(greeting, "keydown", { key: "Enter" });
  const limit = row(page.container, "limit").querySelector<HTMLInputElement>("input")!;
  await changeValue(limit, "25");
  await fire(limit, "keydown", { key: "Enter" });
  expect(sets(page.provider).slice(1)).toEqual([
    { app: "acme/standup", values: { size: "large" } },
    { app: "acme/standup", values: { greeting: "Hi team" } },
    { app: "acme/standup", values: { limit: 25 } },
  ]);
  expect(page.provider.extensionApps[0]!.stored).toEqual({
    compact: true,
    size: "large",
    greeting: "Hi team",
    limit: 25,
  });
  expect(row(page.container, "limit").querySelector<HTMLInputElement>("input")!.value).toBe("25");
  page.unmount();
});

test("Reset to Default in the row's menu sends null and the row shows the manifest's default", async () => {
  const page = await renderCard(<ExtensionsCard />, (provider) => {
    provider.extensionApps[0]!.stored = { size: "large" };
  });
  expect(row(page.container, "size").querySelector<HTMLSelectElement>("select")!.value).toBe("large");
  await fire(row(page.container, "size").querySelector(".row-title")!, "contextmenu");
  const reset = [...document.querySelectorAll<HTMLElement>("[role=menu] [role=menuitem]")].find(
    (item) => item.textContent === "Reset to Default",
  )!;
  await click(reset);
  expect(sets(page.provider)).toEqual([{ app: "acme/standup", values: { size: null } }]);
  expect(row(page.container, "size").querySelector<HTMLSelectElement>("select")!.value).toBe("small");
  page.unmount();
});

test("a value the manifest refuses shows the daemon's reason and the row keeps the stored value", async () => {
  const page = await renderCard(<ExtensionsCard />, (provider) => {
    provider.extensionApps[0]!.schema.properties.limit!.maximum = 20;
  });
  const limit = row(page.container, "limit").querySelector<HTMLInputElement>("input")!;
  // The field clamps to the manifest's range, so the daemon's own check is reached with a stale
  // schema: the mock's manifest now says 15 is the most.
  page.provider.extensionApps[0]!.schema.properties.limit!.maximum = 15;
  await changeValue(limit, "18");
  await fire(limit, "keydown", { key: "Enter" });
  const problem = page.container.querySelector('[data-extension="acme/standup"] [data-extension-problem]');
  expect(problem?.textContent).toBe("This extension doesn't allow that value.");
  expect(page.provider.extensionApps[0]!.stored).toEqual({});
  page.unmount();
});

test("with no extension that declares settings, or a host without them, the card says so", async () => {
  const empty = await renderCard(<ExtensionsCard />, (provider) => {
    provider.extensionApps = [];
  });
  expect(empty.container.querySelector("[data-extensions-empty]")).not.toBeNull();
  empty.unmount();
  const old = await renderCard(<ExtensionsCard />, (provider) => {
    provider.extensionsUnsupported = true;
  });
  expect(old.container.querySelector("[data-extensions-unavailable]")).not.toBeNull();
  old.unmount();
});

test("a setting this page cannot draw is left out, and a localized title shows its text", () => {
  const apps = readExtensionSettings({
    apps: [
      {
        app: "acme/x",
        name: { key: "name", text: "X" },
        schema: {
          type: "object",
          properties: {
            tags: { type: "array", default: [] },
            mode: { type: "string", enum: ["a", "b"], title: { key: "mode", text: "Mode" }, default: "a" },
          },
        },
        values: { mode: "b" },
      },
      { app: "acme/none", schema: { type: "object", properties: { list: { type: "array" } } } },
    ],
  });
  expect(apps.map((app) => app.app)).toEqual(["acme/x"]);
  expect(apps[0]!.name).toBe("X");
  expect(apps[0]!.settings.map((setting) => [setting.key, setting.kind, setting.title])).toEqual([
    ["mode", "choice", "Mode"],
  ]);
});

// The layout source the exported schema comes from (the PR autofix regenerates settings-schema.json
// from it on a Mac): Extensions is a category of its own that leads with the card, and its symbol
// has an icon.
test("the Extensions category draws the card", () => {
  expect(CATEGORY_CARDS).toContain("extensions");
  const layout = JSON.parse(
    readFileSync(new URL("../../../../schemas/settings/source/page-layout.json", import.meta.url), "utf8"),
  ) as {
    cards: Array<{ id: string }>;
    sidebar_sections: Array<{ categories: Array<{ id: string; symbol: string; lead?: string[] }> }>;
  };
  expect(layout.cards.map((card) => card.id)).toContain("extensions");
  const category = layout.sidebar_sections.flatMap((run) => run.categories).find((entry) => entry.id === "extensions");
  expect(category?.lead).toEqual(["extensions"]);
  expect(hasIcon(category!.symbol)).toBe(true);
  // Once the export is regenerated, the page draws the same category.
  const exported = categories.find((entry) => entry.id === "extensions");
  if (exported) expect(exported.lead).toEqual(["extensions"]);
});

test("a DEV-only setting shows only in a DEV build", async () => {
  const addVariant = (provider: Parameters<NonNullable<Parameters<typeof renderCard>[1]>>[0]) => {
    provider.extensionApps[0]!.schema.properties.variant = {
      type: "string",
      title: "Design variant",
      enum: ["menu", "pane"],
      default: "menu",
      "x-cmux-devOnly": true,
    };
  };
  const release = await renderCard(<ExtensionsCard />, (provider) => {
    addVariant(provider);
    provider.host = { ...provider.host, dev_build: false };
  });
  expect(row(release.container, "variant")).toBeNull();
  expect(row(release.container, "compact")).not.toBeNull();
  release.unmount();
  const dev = await renderCard(<ExtensionsCard />, (provider) => {
    addVariant(provider);
    provider.host = { ...provider.host, dev_build: true };
  });
  expect(row(dev.container, "variant")).not.toBeNull();
  dev.unmount();
});
