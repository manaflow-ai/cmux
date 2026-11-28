import { describe, expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import { autoSizeRowView } from "./autosizeModel";
import {
  GREW_FOR_MEMORY,
  HELD_AT_PLAN_LIMIT,
  HELD_SHARED,
  HELD_UNKNOWN_CODE,
  SHRANK_IDLE,
} from "./autosizeModel.fixtures";

const t = translatorFor("en");

describe("autoSizeRowView", () => {
  test("a grow names the new shape, the reason, the rate and its rise", () => {
    const view = autoSizeRowView(GREW_FOR_MEMORY, t, "en");
    expect(view.title).toBe("Grew to 4 vCPU / 8 GiB");
    expect(view.why).toBe("it ran out of memory");
    expect(view.rate).toBe("$0.296 an hour");
    expect(view.change).toBe("+$0.148");
    expect(view.repeats).toBe("");
    expect(view.upgrade).toBeUndefined();
  });

  test("a shrink shows the drop", () => {
    const view = autoSizeRowView(SHRANK_IDLE, t, "en");
    expect(view.title).toBe("Shrank to 2 vCPU / 4 GiB");
    expect(view.why).toBe("it was idle");
    expect(view.change).toBe("−$0.148");
  });

  test("a plan-limit hold offers the plan above and counts its repeats", () => {
    const view = autoSizeRowView(HELD_AT_PLAN_LIMIT, t, "en");
    expect(view.title).toBe("Stayed at 2 vCPU / 4 GiB");
    expect(view.why).toBe("your plan's limit");
    expect(view.change).toBe("");
    expect(view.repeats).toBe("×3");
    expect(view.upgrade).toBe("Upgrade to Pro for 8 vCPU / 32 GiB");
    expect(autoSizeRowView(HELD_SHARED, t, "en").upgrade).toBeUndefined();
  });

  test("a hold code with no words of its own reads the server's line", () => {
    expect(autoSizeRowView(HELD_UNKNOWN_CODE, t, "en").why).toBe(HELD_UNKNOWN_CODE.line);
  });

  test("another language formats numbers and money its own way", () => {
    const view = autoSizeRowView(GREW_FOR_MEMORY, translatorFor("de"), "de");
    expect(view.rate).toContain("0,296");
  });
});
