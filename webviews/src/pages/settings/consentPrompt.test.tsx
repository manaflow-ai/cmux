import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { rowsByKey, schema, type SchemaRow } from "./schema";
import { text } from "./strings";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());

const KEY = "diagnostics.shareInstallCounts";
const HELP = "Sends cmux the names of packages agents install.";

/** The row, on the Privacy page, when the checked-in export (regenerated on a Mac) lacks it. */
if (!rowsByKey.has(KEY)) {
  const like = rowsByKey.get("diagnostics.hangReports");
  if (!like) throw new Error("no Hang Reports row to copy");
  const row: SchemaRow = {
    ...structuredClone(like),
    key: KEY,
    path: ["diagnostics", "shareInstallCounts"],
    default: false,
    title: { key: "settings.diagnostics.shareInstallCounts", text: "Share Package Installs to Improve cmux" },
    help: { key: "settings.diagnostics.shareInstallCounts.help", text: HELP },
  };
  schema.rows.push(row);
  (rowsByKey as Map<string, SchemaRow>).set(KEY, row);
  const group = schema.page.categories
    .find((category) => category.id === "privacy")
    ?.groups.find((g) => g.rows.includes("diagnostics.usagePatterns"));
  if (!group) throw new Error("no Usage Patterns group on the Privacy page");
  group.rows.push(KEY);
}

const { click, ops, renderPage, rowElement } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

describe("consent before sharing", () => {
  test("crash reports and analytics ask before turning on", async () => {
    const { CONSENT_ROWS } = await import("./components/ConsentPrompt");
    expect(CONSENT_ROWS.has("app.sendAnonymousTelemetry")).toBe(true);
  });

  test("turning install counts on shows the consent text first; Turn On writes true", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const row = () => rowElement(page!.container, KEY);
    await click(row().querySelector("[role=switch]")!);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    const prompt = row().querySelector(`[data-consent-prompt="${KEY}"]`);
    expect(prompt?.textContent).toContain(text(rowsByKey.get(KEY)!.help));
    await click(row().querySelector('[data-consent-action="accept"]')!);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: KEY, value: true }]);
    expect(row().querySelector("[data-consent-prompt]")).toBeNull();
  });

  test("Cancel writes nothing; turning it off never asks", async () => {
    page = await renderPage({ path: "/settings/privacy" });
    const row = () => rowElement(page!.container, KEY);
    await click(row().querySelector("[role=switch]")!);
    await click(row().querySelector('[data-consent-action="cancel"]')!);
    expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
    expect(row().querySelector("[data-consent-prompt]")).toBeNull();
    page.unmount();
    page = await renderPage({ path: "/settings/privacy", mock: { values: { [KEY]: true } } });
    await click(rowElement(page.container, KEY).querySelector("[role=switch]")!);
    expect(rowElement(page.container, KEY).querySelector("[data-consent-prompt]")).toBeNull();
    expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: KEY, value: false }]);
  });
});
