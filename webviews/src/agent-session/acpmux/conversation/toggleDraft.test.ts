import { describe, expect, test } from "bun:test";

import { inlineToken, type ComposerAttachment } from "../attachments";
import {
  composerFilledReporter,
  putToggleDraft,
  takeToggleDraft,
  toggleDraft,
  type ToggleDraftComposer,
} from "./toggleDraft";

const chip: ComposerAttachment = { id: "c1", kind: "image", name: "shot.png", mimeType: "image/png", size: 10 };

/// A composer that holds `text` and `attachments`, and records what the swap did to it.
function composer(text: string, attachments: ComposerAttachment[] = []) {
  const held = { text, attachments, takes: 0, restores: [] as string[] };
  const handle: ToggleDraftComposer = {
    draft: () => ({ text: held.text, attachments: held.attachments }),
    take: () => {
      const taken = { text: held.text, attachments: held.attachments };
      held.text = "";
      held.attachments = [];
      held.takes += 1;
      return taken;
    },
    restore: (restored) => {
      held.restores.push(restored);
      held.text = restored + held.text;
    },
  };
  return { held, handle };
}

describe("Toggle Terminal and Chat's draft (the unsent draft goes with the swap)", () => {
  test("plain text leaves as it is typed, new lines and all", () => {
    expect(toggleDraft({ text: "fix the login bug", attachments: [] })).toBe("fix the login bug");
    expect(toggleDraft({ text: "one\ntwo", attachments: [] })).toBe("one\ntwo");
  });

  test("nothing leaves from an empty composer, one with chips, or one with inline tokens", () => {
    expect(toggleDraft(undefined)).toBeNull();
    expect(toggleDraft({ text: "", attachments: [] })).toBeNull();
    expect(toggleDraft({ text: "  \n", attachments: [] })).toBeNull();
    expect(toggleDraft({ text: "see this", attachments: [chip] })).toBeNull();
    expect(toggleDraft({ text: `see ${inlineToken("c1")} here`, attachments: [] })).toBeNull();
  });

  test("the take empties the composer only while it holds the pasted draft, before the deadline", () => {
    const { held, handle } = composer("ship it");
    // The person typed on after the read: the composer keeps it.
    expect(takeToggleDraft(handle, "ship", undefined)).toBe(false);
    // Too late: the chat may already show.
    expect(takeToggleDraft(handle, "ship it", 1_000, 1_001)).toBe(false);
    expect(held.takes).toBe(0);
    expect(takeToggleDraft(handle, "ship it", 1_000, 999)).toBe(true);
    expect(held.text).toBe("");
    expect(takeToggleDraft(undefined, "ship it", undefined)).toBe(false);
  });

  test("the put fills only an empty composer, before the deadline: two drafts never merge", () => {
    const full = composer("mine");
    expect(putToggleDraft(full.handle, "from the terminal", undefined)).toBe(false);
    expect(full.held.text).toBe("mine");
    const chips = composer("", [chip]);
    expect(putToggleDraft(chips.handle, "from the terminal", undefined)).toBe(false);
    const empty = composer("");
    expect(putToggleDraft(empty.handle, "from the terminal", 1_000, 1_001)).toBe(false);
    expect(putToggleDraft(empty.handle, "  ", undefined)).toBe(false);
    expect(empty.held.restores).toEqual([]);
    expect(putToggleDraft(empty.handle, "from the terminal", 1_000, 999)).toBe(true);
    expect(empty.held.text).toBe("from the terminal");
  });

  test("the host hears whether the composer holds anything first, then only when that changes", () => {
    const posts: boolean[] = [];
    const report = composerFilledReporter((filled) => posts.push(filled));
    // The first value goes even when empty: a reloaded page resets what the page before it left.
    report(false);
    report(true);
    report(true);
    report(false);
    expect(posts).toEqual([false, true, false]);
  });
});
