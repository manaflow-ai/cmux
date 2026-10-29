// The remote Chief memory inspector keeps its tab, turn, zoom path and scroll across a discard:
// the hide saves them, and the restored document's inspector opens there.
import { describe, expect, test } from "bun:test";
import type { InspectorView } from "../../optchat-inspector/App";
import { DOCUMENT_SCROLL_KEY, restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { CHIEF_INSPECTOR_PAGE, restoredInspectorView } from "./view";

describe("Chief inspector page state", () => {
  test("a hide, a discard and a restore give the next document the same view and scroll", () => {
    const view: InspectorView = { tab: "tree", turn: "t42", path: ["memory", "projects"] };
    const { client, after } = pageRoundTrip(CHIEF_INSPECTOR_PAGE, {
      scroll: { [DOCUMENT_SCROLL_KEY]: 1100 },
      inputs: () => view,
    }).restore();
    expect(restoredInspectorView(restoredPageInputs(client, CHIEF_INSPECTOR_PAGE))).toEqual(view);
    expect(scrollOf(after, DOCUMENT_SCROLL_KEY)).toBe(1100);
  });

  test("only valid saved fields are taken", () => {
    expect(restoredInspectorView({ tab: "logs", turn: 3, path: ["a", 1] })).toEqual({});
    expect(restoredInspectorView({ tab: "live", path: Array(65).fill("a") })).toEqual({ tab: "live" });
    expect(restoredInspectorView(null)).toEqual({});
  });
});
