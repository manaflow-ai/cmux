import { describe, expect, test } from "bun:test";
import { afterLatestFooter } from "./OpenAppCard";

describe("the after-latest footer", () => {
  // An empty footer kept the composer's room below the transcript and shortened it (review of #34566).
  test("is absent with no card and no tray", () => {
    expect(afterLatestFooter(null, null)).toBeUndefined();
    expect(afterLatestFooter(undefined, null)).toBeUndefined();
  });

  test("shows when either the card or the tray has content", () => {
    expect(afterLatestFooter(<div />, null)).toBeDefined();
    expect(afterLatestFooter(null, <div />)).toBeDefined();
  });
});
