// Mobile Pairing keeps its scroll across a discard. The host owns the pairing
// status and the switch, and the page has no field, so it saves no inputs of its own.
import { describe, expect, test } from "bun:test";
import { DOCUMENT_SCROLL_KEY, restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { MOBILE_PAIRING_PAGE } from "./store";

describe("Mobile Pairing page state", () => {
  test("a hide, a discard and a restore give the next document the same scroll", () => {
    const { client, after } = pageRoundTrip(MOBILE_PAIRING_PAGE, { scroll: { [DOCUMENT_SCROLL_KEY]: 380 } }).restore();
    expect(restoredPageInputs(client, MOBILE_PAIRING_PAGE)).toBeUndefined();
    expect(scrollOf(after, DOCUMENT_SCROLL_KEY)).toBe(380);
  });
});
