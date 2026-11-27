// The orange allowlist's `looks` key (schemas/theme/orange-accent-allowlist.json) admits only its golden looks, each
// on its own looks.golden stage: no other entry, variant or theme reads it (test/support/orangeAccentAllowlist.ts).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { GOLDEN_LOOKS_ENTRY, orangeAllowedFor, readOrangeAccentAllowlist } from "./support/orangeAccentAllowlist";

const webviews = path.resolve(import.meta.dir, "..");
const allowlist = readOrangeAccentAllowlist(webviews);
const allowed = orangeAllowedFor(allowlist);
const lookIds = (
  JSON.parse(fs.readFileSync(path.join(webviews, "src/gallery/golden/looks.json"), "utf8")) as {
    looks: { id: string }[];
  }
).looks.map((look) => look.id);

test("the allowlisted looks are exactly the Claude and Tandem golden looks, and both exist", () => {
  expect((allowlist.looks ?? []).map((look) => look.id).sort()).toEqual(["claude", "tandem-addon"]);
  for (const look of allowlist.looks ?? []) expect(lookIds).toContain(look.id);
});

test("a look is honored on its own looks.golden stage and nowhere else", () => {
  for (const id of ["claude", "tandem-addon"]) {
    expect(allowed({ entry: GOLDEN_LOOKS_ENTRY, variant: id, theme: undefined })).toBe(true);
    // The golden Settings page draws the same look on its own stages.
    expect(allowed({ entry: "looks.golden.settings.appearance", variant: id, theme: undefined })).toBe(true);
    expect(allowed({ entry: "looks.golden.settings.chat", variant: id, theme: "Dracula" })).toBe(false);
    // Another entry with a variant of the same name, or the same stage under another theme, is not admitted.
    expect(allowed({ entry: "agent-pane.composer", variant: id, theme: undefined })).toBe(false);
    expect(allowed({ entry: "looks.golden.extra", variant: id, theme: undefined })).toBe(false);
    expect(allowed({ entry: GOLDEN_LOOKS_ENTRY, variant: id, theme: "Dracula" })).toBe(false);
  }
  // Every other golden look stays under the orange rule.
  for (const id of lookIds.filter((id) => id !== "claude" && id !== "tandem-addon"))
    expect(allowed({ entry: GOLDEN_LOOKS_ENTRY, variant: id, theme: undefined })).toBe(false);
});

test("the theme allowlist is unchanged by the looks key", () => {
  expect(allowed({ entry: "agent-pane.composer", variant: "default", theme: "Clay Orange" })).toBe(true);
  expect(allowed({ entry: "agent-pane.composer", variant: "default", theme: undefined })).toBe(false);
});
