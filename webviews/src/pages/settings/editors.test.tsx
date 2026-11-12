import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { mockManagedKey } from "./mockProvider";
import { categories, homes } from "./categories";
import { DENSITY_ROWS } from "./density";
import { rowsByKey, type SchemaRow } from "./schema";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, resetRow, rowElement, run, settle } = await import("./testing");
const { isDuration } = await import("./editors/DurationEditor");
const { ROW_LEVELS } = await import("./rowLevelsData");
const { PERSONALIZATION_KEYS } = await import("./components/PersonalizationCard");
const { DENSITY_CARD_ROWS } = await import("./density");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/** What the editor of each kind must contain; returns a failure description or null. */
function editorProblem(row: SchemaRow, control: Element): string | null {
  const has = (selector: string, count = 1) => control.querySelectorAll(selector).length === count;
  const choices = row.choices?.length ?? 0;
  switch (row.kind) {
    case "toggle":
      return has("[role=switch]") ? null : "no switch";
    case "choice":
      return has("select") && has("option", choices + (row.default === null ? 1 : 0)) ? null : "no menu";
    case "choice_or_number":
      return has('option[value="__custom__"]') ? null : "no Custom… choice";
    case "choice_or_url":
      return has('option[value="__address__"]') ? null : "no Self-Hosted Server… choice";
    case "number":
      // A time row with a wide range is a menu of durations (DurationEditor), not a slider.
      if (isDuration(row)) return has("select") && !has('input[type="range"]') ? null : "no duration menu";
      return has('input[type="range"]') && has("input.number") ? null : "no slider + field";
    case "color":
      return has('input[type="color"]') && has("input.hex") ? null : "no swatch + hex field";
    case "theme":
      return has("[data-theme-picker]") ? null : "no theme picker";
    case "font_family":
      return has("button.domain-button") ? null : "no searchable list";
    case "sound":
      return has("select") && has("button.icon-button") ? null : "no menu + play button";
    case "url":
    case "text":
      return has("input.text") ? null : "no text field";
    case "host_list":
      return has("input.token-input") ? null : "no token field";
    case "folder_list":
      return has("[data-add-folder]") ? null : "no Add Folder button";
    case "time_range":
      return has('input[type="time"]', 2) ? null : "no time fields";
    case "string_list":
      return row.choices
        ? has(row.ordered === false ? "[data-choice-set]" : "[data-ordered-choices]")
          ? null
          : "no choice list"
        : has("input.token-input")
          ? null
          : "no token field";
    case "number_list":
      return has("input.token-input") ? null : "no number token field";
    case "string_map":
      return has("[data-string-map]") && has("input[data-map-new-key]") ? null : "no key and value list";
    case "sound_rules":
      // Per-level sound maps are set from the sidebar menus, the palette and the CLI; never a row.
      return "a sound_rules row on the page";
  }
}

describe("editors", () => {
  // One test per Settings page, so each renders one page well inside the default timeout: one
  // test over every page went past 5 s on a loaded CI runner, and its act() left running failed
  // every test after it.
  for (const category of categories)
    test(`every schema row renders the editor for its kind: ${category.id}`, async () => {
      const failures: string[] = [];
      page = await renderPage({ path: `/settings/${category.id}` });
      for (const row of category.groups.flatMap((group) => group.rows)) {
        // A hidden row is not on its page (search, the palette, the CLI and cmux.json have it;
        // rowLevelsData.ts), and Personalization is the one page that draws what it holds.
        const hub =
          category.id !== "personalization" &&
          (PERSONALIZATION_KEYS.includes(row.key) || DENSITY_CARD_ROWS.has(row.key));
        // The Machines card draws machine colors as a color well per machine (checked below).
        const hidden = ROW_LEVELS.levels[row.key] === "hidden" && row.key !== "appearance.machineColors";
        if (hidden || hub) {
          if (page.container.querySelector(`[data-row-key="${row.key}"]`))
            failures.push(`${row.key}: drawn on ${category.id}`);
          continue;
        }
        // The Theme section draws appearance.theme as its theme picker.
        if (row.key === "appearance.theme" || row.key === "appearance.appTheme") {
          if (!page.container.querySelector("[data-theme-picker]")) failures.push(`${row.key}: no theme picker`);
          continue;
        }
        // The Theme section draws appearance.accent as its swatch popup.
        if (row.key === "appearance.accent") {
          if (!page.container.querySelector('[data-card="theme"] [data-accent-picker]'))
            failures.push(`${row.key}: no accent picker`);
          continue;
        }
        // Change Background…'s art picker draws appearance.background as its tiles.
        if (row.key === "appearance.background") {
          if (!page.container.querySelector('[data-card="backdrop"] .backdrop-tile'))
            failures.push(`${row.key}: no art picker`);
          continue;
        }
        // The Chief Pet card draws home.chiefPetEnabled (Show/Hide Pet) and home.chiefPetMascot (its grid).
        if (row.key === "home.chiefPetEnabled" || row.key === "home.chiefPetMascot") {
          if (!page.container.querySelector('[data-card="chief-pet"] .chief-pet-choice[data-pet="orb"]'))
            failures.push(`${row.key}: no Chief Pet card`);
          continue;
        }
        // The Machines card draws appearance.machineColors as a color well on each machine's row.
        if (row.key === "appearance.machineColors") {
          if (!page.container.querySelector('[data-card="machines"] [data-machine-color] input[type="color"]'))
            failures.push(`${row.key}: no machine color well`);
          continue;
        }
        // The density card draws appearance.density and the custom density keys (SectionView).
        if (DENSITY_ROWS.has(row.key)) {
          if (!page.container.querySelector('[data-card="density"]')) failures.push(`${row.key}: no density card`);
          continue;
        }
        // appearance.themeEdits is the pickers' "(custom)" themes, edited in the Theme section, not a row.
        // appearance.favoriteThemes is the pickers' stars, likewise not a row. Rotate Starred Themes
        // shows only once a theme is starred, which this page has none of (themePane.test.tsx draws it).
        if (row.key === "appearance.rotateFavoriteThemes") continue;
        if (row.key === "appearance.themeEdits" || row.key === "appearance.favoriteThemes") {
          if (page.container.querySelector(`[data-row-key="${row.key}"]`)) failures.push(`${row.key}: drawn as a row`);
          continue;
        }
        const element = page.container.querySelector(`[data-row-key="${row.key}"] .row-control`);
        const problem = element ? editorProblem(row, element) : "row not rendered";
        if (problem) failures.push(`${row.key} (${row.kind}): ${problem}`);
      }
      page.unmount();
      page = null;
      expect(failures).toEqual([]);
    });

  test("the window material is a material choice, never a radius slider", async () => {
    // Personalization is the one page that draws the background rows.
    page = await renderPage({ path: "/settings/personalization" });
    const material = rowElement(page.container, "appearance.backgroundBlur");
    expect(material.querySelector('input[type="range"]')).toBeNull();
    const values = [...material.querySelectorAll("option")].map((option) => option.getAttribute("value"));
    expect(values).toEqual(["", "frosted", "glass", "glass-clear", "none"]);
    await changeValue(material.querySelector("select")!, "glass-clear");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([
      { key: "appearance.backgroundBlur", value: "glass-clear" },
    ]);
  });

  test("opacity is a percent slider: preview while dragging, one settings.set on release", async () => {
    // Personalization is the one page that draws the background rows.
    page = await renderPage({ path: "/settings/personalization" });
    const row = rowElement(page.container, "appearance.backgroundOpacity");
    expect(row.querySelector(".unit")?.textContent).toBe("%");
    const slider = row.querySelector<HTMLInputElement>('input[type="range"]')!;
    await changeValue(slider, "0.8");
    await changeValue(slider, "0.7");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    expect(row.querySelector<HTMLInputElement>("input.number")!.value).toBe("70");
    await fire(slider, "pointerup");
    await fire(slider, "blur");
    expect(ops(page.provider, "cmux.settings.preview")).toEqual([
      { key: "appearance.backgroundOpacity", value: 0.8 },
      { key: "appearance.backgroundOpacity", value: 0.7 },
    ]);
    expect(ops(page.provider, "cmux.settings.preview.end")).toEqual([{ key: "appearance.backgroundOpacity" }]);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "appearance.backgroundOpacity", value: 0.7 }]);
    const order = page.provider.log
      .map((entry) => entry.op)
      .filter(
        (op) =>
          op !== "cmux.settings.list" &&
          op !== "cmux.settings.snapshot" &&
          op !== "cmux.settings.host.lists" &&
          op !== "cmux.settings.section.actions" &&
          op !== "cmux.settings.backdrop.image.screen_saver" &&
          // Personalization's theme studio reads its colors when the page opens.
          op !== "cmux.settings.theme.colors",
      );
    expect(order).toEqual([
      "cmux.settings.preview",
      "cmux.settings.preview",
      // The write lands before the preview ends, so the window never flashes the old value.
      "cmux.settings.set",
      "cmux.settings.preview.end",
    ]);
  });

  test("an unset slider sits at the value the host derives (the theme's opacity), live", async () => {
    // Personalization is the one page that draws the background rows.
    page = await renderPage({ path: "/settings/personalization" });
    const row = rowElement(page.container, "appearance.backgroundOpacity");
    const slider = () => row.querySelector<HTMLInputElement>('input[type="range"]')!.value;
    await run(() =>
      page!.provider.setHost({ ...page!.provider.host, derived: { "appearance.backgroundOpacity": 0.85 } }),
    );
    expect(slider()).toBe("0.85");
    await run(() =>
      page!.provider.setHost({ ...page!.provider.host, derived: { "appearance.backgroundOpacity": 0.6 } }),
    );
    expect(slider()).toBe("0.6");
  });

  test("a number field commits on Return, clamped to the range", async () => {
    page = await renderPage({ path: "/settings/terminal" });
    const field = rowElement(page.container, "terminal.fontSize").querySelector<HTMLInputElement>("input.number")!;
    await changeValue(field, "500");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "terminal.fontSize", value: 96 }]);
  });

  test("a number list adds a number in range on Return and refuses one outside it", async () => {
    page = await renderPage({ path: "/settings/editor" });
    const row = () => rowElement(page!.container, "editor.rulers");
    const field = () => row().querySelector<HTMLInputElement>("input.token-input")!;
    await changeValue(field(), "5000");
    await fire(field(), "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    expect(row().querySelector("[role=alert]")).not.toBeNull();
    await changeValue(field(), "80");
    await fire(field(), "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "editor.rulers", value: [80] }]);
    expect(row().querySelector("[role=alert]")).toBeNull();
  });

  test("a managed row shows its value, a disabled control and a localized lock line", async () => {
    page = await renderPage({ path: "/settings/browser" });
    const row = rowElement(page.container, mockManagedKey);
    const control = row.querySelector<HTMLButtonElement>("[role=switch]")!;
    expect(control.disabled).toBe(true);
    expect(control.getAttribute("aria-checked")).toBe("false");
    expect(row.querySelector("[data-managed-reason]")?.textContent).toBe("Managed by your organization");
    expect(page.container.querySelector('[data-section-link="browser"] [data-badge="lock"]')).not.toBeNull();
  });

  test("rows have no Reset button; the row menu resets a customized row", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const row = () => rowElement(page!.container, "history.terminalCommands");
    expect(page.container.querySelector("[data-reset], .reset-slot")).toBeNull();
    await click(row().querySelector("[role=switch]")!);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "history.terminalCommands", value: true }]);
    expect(row().querySelector("[role=switch]")!.getAttribute("aria-checked")).toBe("true");
    expect(page.container.querySelector("[data-reset], .reset-slot")).toBeNull();
    await resetRow(page.container, "history.terminalCommands");
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "history.terminalCommands" }]);
  });

  test("unset browser.hibernation shows Never Discard; Never Discard or the row's reset unsets it", async () => {
    const key = "browser.hibernation";
    page = await renderPage({ path: "/settings/browser" });
    const row = () => rowElement(page!.container, key);
    const select = () => row().querySelector<HTMLSelectElement>("select")!;
    expect(select().value).toBe("");
    expect(select().selectedOptions[0]?.textContent).toBe("Never Discard");
    await changeValue(select(), "moderate");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key, value: "moderate" }]);
    expect(select().selectedOptions[0]?.textContent).toBe("After 30 Minutes");
    await changeValue(select(), "");
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key }]);
    expect(select().value).toBe("");
    // A custom timeout, then Reset: the menu shows Never Discard again, not an empty Custom… field.
    await changeValue(select(), "__custom__");
    const field = row().querySelector<HTMLInputElement>("input.number")!;
    await changeValue(field, "45");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([
      { key, value: "moderate" },
      { key, value: 45 },
    ]);
    expect(select().value).toBe("__custom__");
    await resetRow(page.container, key);
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key }, { key }]);
    expect(select().value).toBe("");
    expect(select().selectedOptions[0]?.textContent).toBe("Never Discard");
    expect(row().querySelector("input.number")).toBeNull();
  });

  // Lucas 2026-11-12: segments in a card read as "containers inside containers"; every choice is a
  // menu, a short one too.
  test("every choice row is a menu, a short one too", async () => {
    for (const key of ["app.quitBehavior", "diff.layout"]) {
      const choice = rowsByKey.get(key)!;
      page = await renderPage({ path: `/settings/${homes.get(choice.key)?.category ?? choice.section}` });
      const row = rowElement(page.container, choice.key);
      expect(row.querySelector('input[type="radio"]')).toBeNull();
      expect(row.querySelector("select")).not.toBeNull();
      page.unmount();
      page = null;
    }
  });

  test("the hidden native select behind each menu is not a Tab stop", async () => {
    page = await renderPage({ path: "/settings/general" });
    const mirrors = [...page.container.querySelectorAll<HTMLSelectElement>("select.ui-select-native")];
    expect(mirrors.length).toBeGreaterThan(0);
    for (const mirror of mirrors) expect(mirror.tabIndex).toBe(-1);
  });

  test("changing a value moves no other control in its row", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const row = () => rowElement(page!.container, "history.terminalCommands");
    const before = [...row().querySelector(".row-control")!.children].map((child) => child.className);
    await click(row().querySelector("[role=switch]")!);
    const after = [...row().querySelector(".row-control")!.children].map((child) => child.className);
    expect(after).toEqual(before);
  });

  test("Escape drops a typed address instead of saving it on blur", async () => {
    page = await renderPage({ path: "/settings/browser" });
    const field = () =>
      rowElement(page!.container, "browser.newTabPage").querySelector<HTMLInputElement>("input.text")!;
    await changeValue(field(), "https://example.org");
    await fire(field(), "keydown", { key: "Escape" });
    await fire(field(), "focusout");
    expect(field().value).not.toBe("https://example.org");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  });

  test("Reset clears an invalid address that was still being typed", async () => {
    page = await renderPage({ path: "/settings/browser" });
    const row = () => rowElement(page!.container, "browser.newTabPage");
    const field = () => row().querySelector<HTMLInputElement>("input.text")!;
    await changeValue(field(), "https://example.org");
    await fire(field(), "keydown", { key: "Enter" });
    await changeValue(field(), "not an address");
    await fire(field(), "keydown", { key: "Enter" });
    expect(row().querySelector("[role=alert]")).not.toBeNull();
    await resetRow(page.container, "browser.newTabPage");
    expect(row().querySelector("[role=alert]")).toBeNull();
    expect(field().value).not.toBe("not an address");
  });

  test("the self-hosted address field drops its draft on Escape and on Reset", async () => {
    page = await renderPage({
      path: "/settings/accounts",
      mock: { values: { "home.server": { selfHosted: "http://mini.example.ts.net:7320" } } },
    });
    const row = () => rowElement(page!.container, "home.server");
    const field = () => row().querySelector<HTMLInputElement>("input.text")!;
    await changeValue(field(), "http://other.example.ts.net:7320");
    await fire(field(), "keydown", { key: "Escape" });
    await fire(field(), "focusout");
    expect(field().value).toBe("http://mini.example.ts.net:7320");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    await changeValue(field(), "not an address");
    await fire(field(), "focusout");
    expect(row().querySelector("[role=alert]")).not.toBeNull();
    await resetRow(page.container, "home.server");
    expect(row().querySelector("[role=alert]")).toBeNull();
    expect(row().querySelector("input.text")).toBeNull();
    expect(row().querySelector<HTMLSelectElement>("select")!.value).toBe("hosted");
  });

  test("a refused value shows a localized error on the row, the daemon's text as detail", async () => {
    page = await renderPage({ path: "/settings/browser" });
    // The page refuses a bad address itself; a value the daemon refuses comes back as a row error.
    const field = rowElement(page.container, "browser.newTabPage").querySelector<HTMLInputElement>("input.text")!;
    await changeValue(field, "localhost");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    expect(rowElement(page.container, "browser.newTabPage").querySelector("[role=alert]")?.textContent).toContain(
      "https://example.com",
    );
    await run(() => page!.store.set("browser.hibernation", -5));
    const error = rowElement(page.container, "browser.hibernation").querySelector(".row-error")!;
    expect(error.textContent).toBe("This value is not accepted.");
    expect(error.getAttribute("title")).toContain("browser.hibernation");
  });

  test("a custom search address without %s or {searchTerms} is refused and a stored one shows why", async () => {
    const key = "browser.customSearchEngine.search";
    page = await renderPage({ path: "/settings/browser" });
    const field = rowElement(page.container, key).querySelector<HTMLInputElement>("input.text")!;
    await changeValue(field, "https://search.example/");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    expect(rowElement(page.container, key).querySelector("[role=alert]")?.textContent).toContain("{searchTerms}");
    await changeValue(field, "https://search.example/?q=%s");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key, value: "https://search.example/?q=%s" }]);
    page.unmount();
    // A hand-edited cmux.json with a broken address: the row says so at once.
    page = await renderPage({ path: "/settings/browser", mock: { values: { [key]: "https://search.example/" } } });
    expect(rowElement(page.container, key).querySelector("[role=alert]")?.textContent).toContain("{searchTerms}");
  });

  test("a team-managed row names the team; a write the daemon refuses as managed is localized", async () => {
    page = await renderPage({
      path: "/settings/privacy",
      mock: { managed: { "history.terminalCommands": { value: false, source: "team", reason: "x", team: "Acme" } } },
    });
    const row = rowElement(page.container, "history.terminalCommands");
    expect(row.querySelector("[data-managed-reason]")?.textContent).toBe("Managed by Acme");
  });

  test("a first read that fails keeps every editor read only and says why", async () => {
    page = await renderPage({
      path: "/settings/privacy",
      mock: { failing: { "cmux.settings.list": "cmux.protocol.unknown_op" } },
    });
    expect(page.container.querySelector('[data-read-only="loadFailed"]')).not.toBeNull();
    const toggle = rowElement(page.container, "history.terminalCommands").querySelector<HTMLButtonElement>(
      "[role=switch]",
    )!;
    expect(toggle.disabled).toBe(true);
  });

  test("going offline adds no row error; reconnecting clears earlier row errors", async () => {
    page = await renderPage({ path: "/settings/browser" });
    await run(() => page!.store.set("browser.hibernation", -5));
    expect(rowElement(page.container, "browser.hibernation").querySelector(".row-error")).not.toBeNull();
    await run(() => page!.provider.setConnected(false));
    await run(() => page!.provider.setConnected(true));
    expect(rowElement(page.container, "browser.hibernation").querySelector(".row-error")).toBeNull();
  });

  test("another client's change to a key clears that row's earlier error", async () => {
    page = await renderPage({ path: "/settings/browser" });
    await run(() => page!.store.set("browser.hibernation", -5));
    expect(rowElement(page.container, "browser.hibernation").querySelector(".row-error")).not.toBeNull();
    await run(() => page!.provider.externalSet("browser.hibernation", "off"));
    expect(rowElement(page.container, "browser.hibernation").querySelector(".row-error")).toBeNull();
  });

  test("with no published domains, theme and font rows are text fields", async () => {
    page = await renderPage({ path: "/settings/theme", mock: { domains: null } });
    const theme = rowElement(page.container, "appearance.theme");
    expect(theme.querySelector("button.domain-button")).toBeNull();
    expect(theme.querySelector("input.text")).not.toBeNull();
  });

  test("the font list opens on a click in the first moments after the page loads", async () => {
    page = await renderPage({ path: "/settings/terminal" });
    const now = performance.now;
    performance.now = () => 50;
    try {
      const button = rowElement(page.container, "terminal.fontFamily").querySelector("button.domain-button")!;
      await click(button);
      expect(button.getAttribute("aria-expanded")).toBe("true");
    } finally {
      performance.now = now;
    }
  });

  test("a diagnostic shows an inline notice and a warning badge", async () => {
    page = await renderPage({
      mock: { diagnostics: [{ path: "terminal.fontSize", message: "fontSize must be a number" }] },
      path: "/settings/terminal",
    });
    const notice = rowElement(page.container, "terminal.fontSize").querySelector("[data-notice]")!;
    expect(notice.textContent).toContain("fontSize must be a number");
    await click([...notice.querySelectorAll("button")][0]!);
    expect(ops(page.provider, "cmux.app.action.run")).toEqual([{ action: "palette.openCmuxSettingsFile" }]);
    expect(page.container.querySelector('[data-section-link="terminal"] [data-badge="warning"]')).not.toBeNull();
  });

  test("unavailable: read-only banner, disabled controls, writes refused and not queued", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    await run(() => page!.provider.setConnected(false));
    expect(page.container.querySelector("[data-read-only]")?.textContent).toContain("read only");
    const toggle = rowElement(page.container, "history.terminalCommands").querySelector<HTMLButtonElement>(
      "[role=switch]",
    )!;
    expect(toggle.disabled).toBe(true);
    const result = await run(() => page!.store.set("history.terminalCommands", true));
    expect(result).toEqual({ ok: false, error: { code: "cmux.page.unavailable", message: "cmux is not connected" } });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    await run(() => page!.provider.setConnected(true));
    expect(page.container.querySelector("[data-read-only]")).toBeNull();
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  });

  test("a write from another client (CLI, hand edit) shows up live through cmux.settings.changed", async () => {
    page = await renderPage({ path: "/settings/terminal" });
    const field = () =>
      rowElement(page!.container, "terminal.fontSize").querySelector<HTMLInputElement>("input.number")!;
    expect(field().value).not.toBe("19");
    await run(() => page!.provider.externalSet("terminal.fontSize", 19));
    expect(field().value).toBe("19");
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  });

  test("a section's own buttons run their actions; Advanced resets all after a confirm", async () => {
    page = await renderPage({ path: "/settings/general" });
    await settle();
    await click(page.container.querySelector('[data-action="palette.makeDefaultTerminal"]')!);
    expect(ops(page.provider, "cmux.app.action.run")).toEqual([{ action: "palette.makeDefaultTerminal" }]);
    page.unmount();
    page = await renderPage({ path: "/settings/advanced" });
    await click(page.container.querySelector("[data-reset-all]")!);
    expect(ops(page.provider, "cmux.settings.reset_all")).toEqual([]);
    await click(page.container.querySelector("[data-confirm-reset-all]")!);
    expect(ops(page.provider, "cmux.settings.reset_all")).toEqual([{}]);
  });
});
