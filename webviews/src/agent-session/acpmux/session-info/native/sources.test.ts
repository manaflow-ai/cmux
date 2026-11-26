import { describe, expect, test } from "bun:test";
import type { Translate } from "../../i18n";
import { NativeInfoActions } from "./model";
import { sourcesSection } from "./sources";

const t = ((key: string) => key) as Translate;

describe("Session Info's native Sources: additional folders", () => {
  test("shows a remove button and removes the selected folder", async () => {
    const removed: string[] = [];
    const actions = new NativeInfoActions();
    const section = sourcesSection(
      {
        sources: [],
        folders: ["/tmp/notes", "/tmp/specs"],
        onRemoveFolder: (folder) => removed.push(folder),
        expanded: false,
        onExpandedChange: () => undefined,
        open: true,
      },
      actions,
      t,
    );

    expect(section?.rows.map((row) => row.id)).toEqual(["folder:/tmp/notes", "folder:/tmp/specs"]);
    const button = section?.rows[0]?.buttons?.[0];
    expect(button).toMatchObject({ label: "composer.removeFolder", symbol: "xmark" });
    expect(actions.run(button!.action)).toBe(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(removed).toEqual(["/tmp/notes"]);
  });

  test("does not expose removal when no callback is provided", () => {
    const section = sourcesSection(
      {
        sources: [],
        folders: ["/tmp/notes"],
        expanded: false,
        onExpandedChange: () => undefined,
        open: true,
      },
      new NativeInfoActions(),
      t,
    );

    expect(section?.rows[0]?.buttons).toBeUndefined();
  });
});
