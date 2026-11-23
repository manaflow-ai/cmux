// The Feed's glyph table is the app's icon pack (the drawings the Swift Feed used): a redrawn icon
// fails here until iconPack.ts is copied again.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { ICON_PACK } from "./iconPack";
import { iconName } from "./icons";
import { iconOf, sampleFeed } from "./mockProvider";

const PACK = path.resolve(
  import.meta.dir,
  "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextIcons/Resources/cmux-icons.json",
);

test("every glyph is the pack's line drawing", () => {
  const pack = JSON.parse(readFileSync(PACK, "utf8")).icons as Record<string, { line: unknown[]; solid: unknown[] }>;
  for (const [name, entry] of Object.entries(ICON_PACK)) {
    expect(pack[name], name).toBeDefined();
    expect(entry.line, name).toEqual(pack[name]!.line as never);
    if (entry.solid) expect(entry.solid, name).toEqual(pack[name]!.solid as never);
  }
});

test("every row icon the owner names is drawn; an unknown name draws the notice bell", () => {
  for (const item of sampleFeed(0)) expect(iconName(iconOf(item))).toBe(iconOf(item));
  for (const kind of [
    "question",
    "choice",
    "confirm",
    "sign-in",
    "passkey",
    "review",
    "input",
    "file",
    "handoff",
    "x-acme.form",
  ])
    expect(iconName(iconOf({ ...sampleFeed(0)[0]!, kind }))).toBe(iconOf({ ...sampleFeed(0)[0]!, kind }));
  expect(iconName("no.such.icon")).toBe("notification");
});
