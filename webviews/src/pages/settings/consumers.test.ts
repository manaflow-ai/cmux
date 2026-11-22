import { describe, expect, test } from "bun:test";
import exported from "../../../../schemas/settings/settings-schema.json";
import { rowsByKey, rowsInSection, schema, sections } from "./schema";
import { searchRows } from "./search";

type ExportedRow = { key: string; consumers: string[]; page_hidden: boolean };
const exportedRows = (exported as unknown as { rows: ExportedRow[] }).rows;

// One cmux.json, two apps: the export lists every key with the apps that read it. The cmux-next
// Settings page renders only keys cmux-next reads, so a cmux-browser key is valid and documented
// but never a control that changes nothing here.
describe("consumers", () => {
  test("the export names consumers on every row and has cmux-browser-only keys", () => {
    expect(exportedRows.every((row) => Array.isArray(row.consumers) && row.consumers.length > 0)).toBe(true);
    const browserOnly = exportedRows.filter((row) => !row.consumers.includes("cmux-next")).map((row) => row.key);
    expect(browserOnly).toContain("browser.toolbar.home");
    expect(browserOnly).toContain("sidebar.workspaceIcons");
  });

  test("no key without cmux-next in consumers appears in the Settings page model", () => {
    const shown = (key: string) => exportedRows.find((row) => row.key === key)?.consumers.includes("cmux-next");
    expect(schema.rows.filter((row) => !shown(row.key)).map((row) => row.key)).toEqual([]);
    expect([...rowsByKey.keys()].filter((key) => !shown(key))).toEqual([]);
    for (const section of sections) {
      expect(
        rowsInSection(section.id)
          .filter((row) => !shown(row.key))
          .map((row) => row.key),
      ).toEqual([]);
    }
    for (const query of ["toolbar", "omnibox", "workspace icons", "traffic light", "strip margin", "presets"]) {
      const found = searchRows(query, () => undefined).flatMap((group) => group.rows);
      expect(found.filter((row) => !shown(row.key)).map((row) => row.key)).toEqual([]);
    }
    // Shared keys stay: cmux-next reads them too.
    expect(rowsByKey.has("appearance.metrics.sidebarWidth")).toBe(true);
  });

  test("page-hidden keys stay in the export but off the page", () => {
    const hidden = exportedRows.filter((row) => row.page_hidden).map((row) => row.key);
    expect(hidden).toContain("notifications.mutedWorkspaces");
    expect(schema.rows.filter((row) => hidden.includes(row.key)).map((row) => row.key)).toEqual([]);
    expect(hidden.filter((key) => rowsByKey.has(key))).toEqual([]);
    const found = searchRows("muted workspaces", () => undefined).flatMap((group) => group.rows);
    expect(found.filter((row) => hidden.includes(row.key)).map((row) => row.key)).toEqual([]);
  });
});
