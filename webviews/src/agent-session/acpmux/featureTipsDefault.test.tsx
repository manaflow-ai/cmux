import { afterEach, describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { FEATURE_TIPS_KEY, setChatDisplay, useFeatureTipsOn } from "./chatDisplay";

// Settings > Updates > Show Feature Tips is off by default (Lawrence 2026-11-20: "drastically simplify
// all parts of the UI"): the host sends only a value the person set, so a missing key means off.
function TipsOn() {
  return <>{useFeatureTipsOn() ? "on" : "off"}</>;
}

describe("feature tips default", () => {
  afterEach(() => setChatDisplay({}));

  test("no stored value: no tips", () => {
    setChatDisplay({});
    expect(renderToString(<TipsOn />)).toBe("off");
  });

  test("the person turned them on", () => {
    setChatDisplay({ [FEATURE_TIPS_KEY]: true });
    expect(renderToString(<TipsOn />)).toBe("on");
  });

  test("the person turned them off", () => {
    setChatDisplay({ [FEATURE_TIPS_KEY]: false });
    expect(renderToString(<TipsOn />)).toBe("off");
  });
});
