// The Home link predicates, ported from Swift `HomeLinkChipKind`: a malformed escape in a file
// path stays a file link instead of throwing while the chat renders.
import { expect, test } from "bun:test";
import { linkChipKind } from "./linkPreview";

test("a file link with a malformed percent escape keeps its kind", () => {
  expect(() => linkChipKind("file:///tmp/%ZZ")).not.toThrow();
  expect(linkChipKind("file:///tmp/notes%ZZ.md")).toBe("markdown");
  expect(linkChipKind("file:///tmp/a%20b.png")).toBe("image");
});
