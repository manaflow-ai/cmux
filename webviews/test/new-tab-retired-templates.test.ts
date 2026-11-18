// Leo 2026-11-18: "The templates should be like the customixastikms api you can build them i don't
// think they should ship as is". Cards, Default, Threads and Console no longer ship (they moved to
// looks, plans/cmux-next/new-tab-templates.md), as the legacy Composer did before them. A saved one
// loads as Minimal, the style dots offer Minimal and Classic, and Terminal draws Minimal.
import { expect, test } from "bun:test";
import { newTabHost } from "../src/agent-session/acpmux/newTabModel";
import {
  NEW_TAB_TEMPLATES,
  PAGE_STYLES,
  RETIRED_NEW_TAB_TEMPLATES,
  pageStyle,
  parseNewTabTemplate,
  shownTemplate,
} from "../src/agent-session/acpmux/newtab/templates";

test("the shipped templates are Minimal, Classic and Terminal", () => {
  expect([...NEW_TAB_TEMPLATES]).toEqual(["minimal", "classic", "terminal"]);
  expect([...PAGE_STYLES]).toEqual(["minimal", "classic"]);
  expect(pageStyle("terminal")).toBe("minimal");
});

test.each([...RETIRED_NEW_TAB_TEMPLATES])("a saved %s template loads as Minimal", (id) => {
  expect(parseNewTabTemplate(id)).toBe("minimal");
  const host = newTabHost({ newTab: { kind: "agent", layout: "b", template: id } });
  expect(host?.template).toBe("minimal");
  expect(shownTemplate(host!)).toBe("minimal");
});

test("the retired ids are exactly the legacy Composer and the four that moved to looks", () => {
  expect([...RETIRED_NEW_TAB_TEMPLATES]).toEqual(["composer", "cards", "default", "threads", "console"]);
});

test("a shipped template reads as itself, anything else as unset", () => {
  for (const id of NEW_TAB_TEMPLATES) expect(parseNewTabTemplate(id)).toBe(id);
  for (const value of ["sparkles", "", 3, null, undefined, "Minimal"]) expect(parseNewTabTemplate(value)).toBeUndefined();
});
