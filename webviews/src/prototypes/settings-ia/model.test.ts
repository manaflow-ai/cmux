// The six-page grouping of the settings navigation prototype covers the real registry exactly:
// every category a release build shows is on one page, none on two.
import { expect, test } from "bun:test";
import "../../pages/settings/testCatalog";
import { SIX_PAGES, unplaced, search } from "./model";

test("six pages place every shown category once", () => {
  expect(SIX_PAGES).toHaveLength(6);
  expect(unplaced()).toEqual({ missing: [], twice: [] });
});

test("the prototype searches with the real settings search", () => {
  const keys = search("font size").flatMap((group) => group.rows.map((row) => row.key));
  expect(keys).toContain("terminal.fontSize");
});
