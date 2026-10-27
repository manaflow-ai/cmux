// A History document that comes back after a discard (PageWebView+Discard.swift) renders its first
// frame from the query it saved when it hid: the bridge client takes the host's restore when it is
// made, and the store starts from it, before React reads the store for the first render.
import { afterAll, describe, expect, test } from "bun:test";
import { installDom } from "../settings/testDom";
const restoreDom = installDom();
import { act } from "react";
import { createRoot } from "react-dom/client";
import { BridgePageClient, RESTORE_NAME, type ReplyHandler } from "../shared/pageClient";
import { PAGE_STATE_VERSION } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { HistoryPage } from "./HistoryPage";
import { HISTORY_PAGE, HistoryStore, restoredQuery } from "./store";

afterAll(() => restoreDom());

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

/** The client of a restored History document whose old one saved `inputs` (pageState.ts). */
function restoredClient(inputs: unknown): BridgePageClient {
  const state = { v: PAGE_STATE_VERSION, page: HISTORY_PAGE, entryRoute: "", route: "", scroll: {}, inputs };
  return new BridgePageClient(handler, { [RESTORE_NAME]: { wasDiscarded: true, state } });
}

describe("History restore after a discard", () => {
  test("the first render shows the saved query", () => {
    const store = new HistoryStore(restoredClient({ text: "deploy", filter: "commands", grouping: "workspace" }));
    expect(store.getSnapshot()).toMatchObject({ text: "deploy", filter: "commands", grouping: "workspace" });
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    // The first render only: the store's subscribe starts its reads, which this test does not need.
    act(() => root.render(<HistoryPage store={store} strings={createStrings(table)} now={() => 0} />));
    expect(container.querySelector<HTMLInputElement>(".history-search")?.value).toBe("deploy");
    act(() => root.unmount());
    container.remove();
  });

  test("a document that was not discarded starts from the defaults", () => {
    const store = new HistoryStore(new BridgePageClient(handler, {}));
    expect(store.getSnapshot()).toMatchObject({ text: "", filter: "all", grouping: "day" });
  });

  test("only valid saved fields are taken", () => {
    expect(restoredQuery({ text: 4, filter: "nope", grouping: "machine" })).toEqual({ grouping: "machine" });
    expect(restoredQuery(null)).toEqual({});
    expect(restoredQuery("text")).toEqual({});
  });
});
