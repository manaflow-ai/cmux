// l10n-allow-file: synthetic extension chip labels and texts.
import { describe, expect, test } from "bun:test";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { ComposerContributions } from "./extensionCommands";
import { chipText, chipTitle, extensionChipsFrom } from "./extensionChipsModel";

const TESTS = {
  app: "samples/team-flow",
  extension: "Team flow",
  id: "tests",
  label: "Tests",
  insert: "Fix the tests.",
};

describe("extension chips", () => {
  test("reads the daemon's chips and drops broken or repeated ones", () => {
    const chips = extensionChipsFrom({
      chips: [
        { ...TESTS, detail: "CI failures" },
        { ...TESTS, label: "Again" },
        { app: "a", id: "x", label: "", insert: "y" },
        { app: "a", id: "x", label: "y" },
        { id: "x", label: "y", insert: "z" },
        null,
      ],
    });
    expect(chips).toEqual([
      {
        key: "samples/team-flow/tests",
        app: "samples/team-flow",
        extension: "Team flow",
        label: "Tests",
        detail: "CI failures",
        insert: "Fix the tests.",
      },
    ]);
    expect(extensionChipsFrom({})).toEqual([]);
    expect(extensionChipsFrom(null)).toEqual([]);
  });

  test("a click's text stands apart from the words around it", () => {
    expect(chipText("", "Fix it.")).toBe("Fix it. ");
    expect(chipText("Please ", "fix it.")).toBe("fix it. ");
    expect(chipText("Please", "fix it.")).toBe(" fix it. ");
    expect(chipText("a", "ends in space ")).toBe(" ends in space ");
  });

  test("the tooltip names the detail and the extension", () => {
    expect(chipTitle({ key: "k", app: "a", label: "l", insert: "i", detail: "d", extension: "E" })).toBe("d · E");
    expect(chipTitle({ key: "k", app: "a", label: "l", insert: "i" })).toBe("");
  });

  test("a save of an extension's chips lists them again, with no reload", async () => {
    const mock = new MockAppPanelsClient();
    const owner = new ComposerContributions(mock);
    const seen: unknown[] = [];
    const stop = owner.subscribe(() => seen.push(owner.getSnapshot()));
    await owner.refresh();
    expect(extensionChipsFrom(owner.getSnapshot())).toEqual([]);
    mock.setComposerChips([TESTS]);
    await owner.refresh();
    expect(extensionChipsFrom(owner.getSnapshot()).map((chip) => chip.label)).toEqual(["Tests"]);
    stop();
  });
});
