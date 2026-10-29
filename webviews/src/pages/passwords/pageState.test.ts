// The Passwords page keeps its search, sort and list scroll across a discard, and
// never a password: the hide saves only what the person typed in the search field.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { FakePageDom, discardAndRestore } from "../shared/pageStateTesting";
import { PASSWORDS_PAGE, PasswordsStore, restoredPasswordsInputs } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

describe("Passwords page state", () => {
  test("a hide, a discard and a restore give the next document the same search, sort and scroll", () => {
    const before = new FakePageDom("");
    before.scroller("list", 3000).scrollTop = 333;
    const store = new PasswordsStore(null);
    openPageState(new BridgePageClient(handler, {}), PASSWORDS_PAGE, before).keep(() => store.pageInputs());
    store.setText("github");
    store.setSort("recent");

    const client = discardAndRestore(before);
    expect(before.lastSaved().inputs).toEqual({ text: "github", sort: "recent" });
    const after = new FakePageDom("");
    const list = after.scroller("list", 3000);
    openPageState(client, PASSWORDS_PAGE, after).keep(() => null);
    expect(new PasswordsStore(client).getSnapshot()).toMatchObject({ text: "github", sort: "recent" });
    expect(list.scrollTop).toBe(333);
  });

  test("only valid saved fields are taken", () => {
    expect(restoredPasswordsInputs({ text: "a", sort: "alphabet" })).toEqual({ text: "a" });
    expect(restoredPasswordsInputs({ sort: "mostUsed" })).toEqual({ sort: "mostUsed" });
    expect(restoredPasswordsInputs(7)).toEqual({});
  });
});
