// Home keeps the open conversation (its route), each conversation's unsent composer text and the
// conversation list's scroll across a discard (p13-webui-082). The timeline is not kept: it opens
// at its newest message, as it does on every visit.
import { describe, expect, test } from "bun:test";
import { restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { COMPOSER_DRAFTS_MAX_CHARS, ComposerDrafts, HOME_CHANNELS_PAGE } from "./composerDrafts";
import { HomeChannelsStore } from "./store";

describe("Home page state", () => {
  test("a hide, a discard and a restore give the next document the same conversation, drafts and scroll", () => {
    const drafts = new ComposerDrafts();
    const trip = pageRoundTrip(HOME_CHANNELS_PAGE, {
      route: "#/",
      scroll: { conversations: 520 },
      inputs: () => drafts.pageInputs(),
    });
    drafts.set("c1", "half a reply");
    drafts.set("c2", "sent already");
    drafts.set("c2", "");
    trip.before.hash = "#/conversation/c1";

    const { client, after } = trip.restore();
    expect(after.hash).toBe("#/conversation/c1");
    const restored = ComposerDrafts.restored(restoredPageInputs(client, HOME_CHANNELS_PAGE));
    const store = new HomeChannelsStore(null, undefined, null, restored);
    expect(store.composerDrafts.get("c1")).toBe("half a reply");
    expect(store.composerDrafts.get("c2")).toBe("");
    expect(scrollOf(after, "conversations")).toBe(520);
  });

  test("the newest drafts are kept within the size the page state holds", () => {
    const drafts = new ComposerDrafts();
    const half = "x".repeat(COMPOSER_DRAFTS_MAX_CHARS / 2 + 1);
    drafts.set("old", half);
    drafts.set("new", half);
    drafts.set("small", "hi");
    expect(drafts.pageInputs()).toEqual({ composers: { small: "hi", new: half } });
  });

  test("only text drafts are taken", () => {
    const drafts = ComposerDrafts.restored({ composers: { a: "text", b: 3, c: "  " } });
    expect(drafts.pageInputs()).toEqual({ composers: { a: "text" } });
    expect(ComposerDrafts.restored("junk").pageInputs()).toEqual({ composers: {} });
  });
});
