// l10n-allow-file: test fixture paths and file text, not shipped UI.
// With the edited-files card off, a turn's edits draw as one grouped line ("Edited 2 files +1 -1").
// A Write whose old contents are unknown (acpmux left its diff a fragment with no old text) counts
// nothing there, as on the card: its written text is not lines added.
//
// Before: the line added the Write's whole text, "+10 -1" beside a one-line Edit, and "+18 -0" for
// two such Writes.
import { expect, test } from "bun:test";
import { CARGO, NOTES, PLAN, SETUP, editWithDiff, translatorWrite, useDom } from "./support/unknownWrite";

const dom = useDom();

async function renderGroup(items: Awaited<ReturnType<typeof translatorWrite>>[]) {
  const { ToolGroupRow } = await import("../src/agent-session/acpmux/conversation/ToolGroupRow");
  await dom.render(<ToolGroupRow kind="edits" disclosureKey={`group:edits:${items[0]!.tool!.id}`} items={items} />);
}

test("beside an Edit, a Write of unknown old contents adds nothing to the group's counts", async () => {
  await renderGroup([
    await translatorWrite("write-1", NOTES, "updated"),
    await editWithDiff("edit-1", CARGO, 'version = "1.2.0"\n', 'version = "1.3.0"\n'),
  ]);
  expect(dom.text(".cv-tool__text")).toStartWith("Edited 2 files");
  expect(dom.text(".cv-tool__counts")).toBe("+1-1");
});

test("a group of only Writes of unknown old contents shows no counts", async () => {
  await renderGroup([
    await translatorWrite("write-2", NOTES, "updated"),
    await translatorWrite("write-3", PLAN, "updated"),
  ]);
  expect(dom.text(".cv-tool__text")).toBe("Edited 2 files");
  expect(dom.host().querySelector(".cv-tool__counts")).toBeNull();
});

test("a Write whose create was confirmed still counts every line as added", async () => {
  await renderGroup([
    await translatorWrite("write-4", SETUP, "created"),
    await editWithDiff("edit-2", CARGO, 'version = "1.2.0"\n', 'version = "1.3.0"\n'),
  ]);
  expect(dom.text(".cv-tool__counts")).toBe("+10-1");
});
