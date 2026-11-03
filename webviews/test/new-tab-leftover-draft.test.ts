// A new chat's text left when its tab opened another chat (cmux#32276) comes back in the window's
// next New Tab page as an editable draft: the host hands it once with the page's context
// (`newTab.draft`), and nothing sends it.
import { expect, test } from "bun:test";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";

test("the New Tab page reads the draft a new chat left in its window", () => {
  const host = newTabHost({ newTab: { layout: "b", kind: "agent", draft: "left in a new chat" } })!;
  expect(host.draft).toBe("left in a new chat");
});

test("a blank or missing draft is none", () => {
  expect(newTabHost({ newTab: { layout: "b", kind: "agent", draft: "  " } })!.draft).toBeUndefined();
  expect(newTabHost({ newTab: { layout: "b", kind: "agent" } })!.draft).toBeUndefined();
});
