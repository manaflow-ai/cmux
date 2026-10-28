// CodeRouter keeps its scroll across a discard. The accounts service owns every
// row and the page has no field, so it saves no inputs of its own.
import { describe, expect, test } from "bun:test";
import { restoredPageInputs } from "../shared/pageState";
import { pageRoundTrip, scrollOf } from "../shared/pageStateTesting";
import { CODEROUTER_PAGE } from "./store";

describe("CodeRouter page state", () => {
  test("a hide, a discard and a restore give the next document the same scroll", () => {
    const { client, after } = pageRoundTrip(CODEROUTER_PAGE, { scroll: { page: 720 } }).restore();
    expect(restoredPageInputs(client, CODEROUTER_PAGE)).toBeUndefined();
    expect(scrollOf(after, "page")).toBe(720);
  });
});
