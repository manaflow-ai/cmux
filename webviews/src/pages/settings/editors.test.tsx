import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { mockManagedKey } from "./mockProvider";
import { schema, sections, type SchemaRow } from "./schema";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, rowElement, run } = await import("./testing");

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
      if (choices <= 3 && row.default !== null)
        return has('input[type="radio"]', choices) ? null : "no segmented control";
      return has("select") && has("option", choices + (row.default === null ? 1 : 0)) ? null : "no menu";
    case "choice_or_number":
      return has('option[value="__custom__"]') ? null : "no Custom… choice";
    case "number":
      return has('input[type="range"]') && has("input.number") ? null : "no slider + field";
    case "color":
      return has('input[type="color"]') && has("input.hex") ? null : "no swatch + hex field";
    case "theme":
    case "font_family":
      return has("button.domain-button") ? null : "no searchable list";
    case "sound":
      return has("select") && has("button.icon-button") ? null : "no menu + play button";
    case "url":
      return has("input.text") ? null : "no text field";
    case "host_list":
      return has("input.token-input") ? null : "no token field";
    case "time_range":
      return has('input[type="time"]', 2) ? null : "no time fields";
  }
}

describe("editors", () => {
  test("every schema row renders the editor for its kind", async () => {
    const failures: string[] = [];
    for (const section of sections) {
      page = await renderPage({ path: `/settings/${section.id}` });
      for (const row of schema.rows.filter((item) => item.section === section.id)) {
        const element = page.container.querySelector(`[data-row-key="${row.key}"] .row-control`);
        const problem = element ? editorProblem(row, element) : "row not rendered";
        if (problem) failures.push(`${row.key} (${row.kind}): ${problem}`);
      }
      page.unmount();
      page = null;
    }
    expect(failures).toEqual([]);
  });

  test("the window material is a material choice, never a radius slider", async () => {
    page = await renderPage({ path: "/settings/appearance" });
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
    page = await renderPage({ path: "/settings/appearance" });
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
        (op) => op !== "cmux.settings.list" && op !== "cmux.settings.snapshot" && op !== "cmux.settings.host.lists",
      );
    expect(order).toEqual([
      "cmux.settings.preview",
      "cmux.settings.preview",
      // The write lands before the preview ends, so the window never flashes the old value.
      "cmux.settings.set",
      "cmux.settings.preview.end",
    ]);
  });

  test("a number field commits on Return, clamped to the range", async () => {
    page = await renderPage({ path: "/settings/terminal" });
    const field = rowElement(page.container, "terminal.fontSize").querySelector<HTMLInputElement>("input.number")!;
    await changeValue(field, "500");
    await fire(field, "keydown", { key: "Enter" });
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "terminal.fontSize", value: 96 }]);
  });

  test("a managed row shows its value, a disabled control and a localized lock line", async () => {
    page = await renderPage({ path: "/settings/browser" });
    const row = rowElement(page.container, mockManagedKey);
    const control = row.querySelector<HTMLButtonElement>("[role=switch]")!;
    expect(control.disabled).toBe(true);
    expect(control.getAttribute("aria-checked")).toBe("false");
    expect(row.querySelector("[data-managed-reason]")?.textContent).toBe("Managed by your organization");
    expect(row.querySelector("[data-reset]")).toBeNull();
    expect(page.container.querySelector('[data-section-link="browser"] [data-badge="lock"]')).not.toBeNull();
  });

  test("the reset button appears only when the row is customized", async () => {
    page = await renderPage({ path: "/settings/general" });
    const row = () => rowElement(page!.container, "history.terminalCommands");
    expect(row().querySelector("[data-reset]")).toBeNull();
    await click(row().querySelector("[role=switch]")!);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "history.terminalCommands", value: true }]);
    expect(row().querySelector("[role=switch]")!.getAttribute("aria-checked")).toBe("true");
    await click(row().querySelector("[data-reset]")!);
    expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "history.terminalCommands" }]);
    expect(row().querySelector("[data-reset]")).toBeNull();
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

  test("a team-managed row names the team; a write the daemon refuses as managed is localized", async () => {
    page = await renderPage({
      path: "/settings/general",
      mock: { managed: { "history.terminalCommands": { value: false, source: "team", reason: "x", team: "Acme" } } },
    });
    const row = rowElement(page.container, "history.terminalCommands");
    expect(row.querySelector("[data-managed-reason]")?.textContent).toBe("Managed by Acme");
  });

  test("a first read that fails keeps every editor read only and says why", async () => {
    page = await renderPage({
      path: "/settings/general",
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
    page = await renderPage({ path: "/settings/appearance", mock: { domains: null } });
    const theme = rowElement(page.container, "appearance.theme");
    expect(theme.querySelector("button.domain-button")).toBeNull();
    expect(theme.querySelector("input.text")).not.toBeNull();
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
    page = await renderPage({ path: "/settings/general" });
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

  test("sections without rows link to the Settings window; Advanced resets all after a confirm", async () => {
    page = await renderPage({ path: "/settings/keyboard" });
    await click(page.container.querySelector(".content .button")!);
    expect(ops(page.provider, "cmux.app.action.run")).toEqual([
      { action: "openSettings", args: { section: "keyboard" } },
    ]);
    page.unmount();
    page = await renderPage({ path: "/settings/advanced" });
    await click(page.container.querySelector("[data-reset-all]")!);
    expect(ops(page.provider, "cmux.settings.reset_all")).toEqual([]);
    await click(page.container.querySelector("[data-confirm-reset-all]")!);
    expect(ops(page.provider, "cmux.settings.reset_all")).toEqual([{}]);
  });
});
