import { describe, expect, it } from "vitest";
import { drawerReducer, encodeCtrlKey } from "../src/lib/mobile";

describe("sticky Ctrl encoding", () => {
  it("maps letters to their ASCII control characters", () => {
    expect(encodeCtrlKey("a")).toBe("\u0001");
    expect(encodeCtrlKey("C")).toBe("\u0003");
    expect(encodeCtrlKey("z")).toBe("\u001a");
  });

  it("rejects keys outside the supported letter range", () => {
    expect(encodeCtrlKey("[")).toBeNull();
    expect(encodeCtrlKey("ab")).toBeNull();
  });
});

describe("drawerReducer", () => {
  it("toggles, closes on selection, and handles explicit actions", () => {
    expect(drawerReducer("closed", "toggle")).toBe("open");
    expect(drawerReducer("open", "toggle")).toBe("closed");
    expect(drawerReducer("open", "select")).toBe("closed");
    expect(drawerReducer("closed", "open")).toBe("open");
    expect(drawerReducer("open", "close")).toBe("closed");
  });
});

