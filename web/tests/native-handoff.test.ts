import { describe, test, expect } from "bun:test";
import { isNativeReturnScheme, shouldEmitNativeHandoff } from "../app/handler/after-sign-in/native-handoff";

describe("native-handoff", () => {
  describe("isNativeReturnScheme", () => {
    test("returns true for valid cmux schemes", () => {
      expect(isNativeReturnScheme("cmux://auth-callback")).toBe(true);
      expect(isNativeReturnScheme("cmux-dev://auth-callback")).toBe(true);
    });

    test("returns false for invalid schemes", () => {
      expect(isNativeReturnScheme("https://cmux.app")).toBe(false);
      expect(isNativeReturnScheme("cmuxapp://auth")).toBe(false);
      expect(isNativeReturnScheme(null)).toBe(false);
      expect(isNativeReturnScheme(undefined)).toBe(false);
      expect(isNativeReturnScheme("")).toBe(false);
    });
  });

  describe("shouldEmitNativeHandoff", () => {
    test("returns true when both tokens are present", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: "access",
        })
      ).toBe(true);
    });

    test("returns false when refreshToken is missing", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: undefined,
          accessToken: "access",
        })
      ).toBe(false);
    });

    test("returns false when accessToken is empty string", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: "",
        })
      ).toBe(false);
    });

    test("returns false when accessToken is undefined", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: undefined,
        })
      ).toBe(false);
    });
  });
});
