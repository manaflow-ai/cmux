import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { rowsByKey, schema, type SchemaRow } from "./schema";
import { text } from "./strings";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, rowElement } = await import("./testing");

const KEY = "diagnostics.shareInstallCounts";
const HELP = "Sends cmux the names of packages agents install.";

/** The row, on the Privacy page, when the checked-in export (regenerated on a Mac) lacks it. */
if (!rowsByKey.has(KEY)) {
  const like = rowsByKey.get("history.terminalCommands");
  if (!like) throw new Error("no Privacy toggle to copy");
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
}

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

describe("consent before sharing", () => {
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

