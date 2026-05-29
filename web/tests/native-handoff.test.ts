import { describe, expect, test } from "bun:test";
import {
  isNativeReturnScheme,
  nativeAuthCallbackForReturnTo,
  shouldEmitNativeHandoff,
} from "../app/handler/after-sign-in/native-handoff";

describe("native-handoff", () => {
  describe("isNativeReturnScheme", () => {
    test("returns true for cmux native schemes", () => {
      expect(isNativeReturnScheme("cmux://auth-callback")).toBe(true);
      expect(isNativeReturnScheme("cmux-nightly://auth-callback")).toBe(true);
      expect(isNativeReturnScheme("cmux-dev://auth-callback")).toBe(true);
    });

    test("returns false for non-native schemes", () => {
      expect(isNativeReturnScheme("https://cmux.com")).toBe(false);
      expect(isNativeReturnScheme("cmuxapp://auth-callback")).toBe(false);
      expect(isNativeReturnScheme(null)).toBe(false);
      expect(isNativeReturnScheme(undefined)).toBe(false);
      expect(isNativeReturnScheme("")).toBe(false);
    });
  });

  describe("nativeAuthCallbackForReturnTo", () => {
    test("coerces native return targets to auth-callback", () => {
      expect(nativeAuthCallbackForReturnTo("cmux://workspace/123")).toBe(
        "cmux://auth-callback",
      );
      expect(
        nativeAuthCallbackForReturnTo("cmux-nightly://workspace/123"),
      ).toBe("cmux-nightly://auth-callback");
      expect(nativeAuthCallbackForReturnTo("cmux-dev://workspace/123")).toBe(
        "cmux-dev://auth-callback",
      );
    });

    test("preserves the callback state", () => {
      expect(
        nativeAuthCallbackForReturnTo("cmux-dev://auth-callback?state=abc123"),
      ).toBe("cmux-dev://auth-callback?state=abc123");
    });

    test("returns null for non-native return targets", () => {
      expect(nativeAuthCallbackForReturnTo("https://cmux.com")).toBe(null);
      expect(nativeAuthCallbackForReturnTo(null)).toBe(null);
      expect(nativeAuthCallbackForReturnTo(undefined)).toBe(null);
    });
  });

  describe("shouldEmitNativeHandoff", () => {
    test("returns true when both tokens are present", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: "access",
        }),
      ).toBe(true);
    });

    test("returns false when refreshToken is missing", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: undefined,
          accessToken: "access",
        }),
      ).toBe(false);
    });

    test("returns false when accessToken is empty string", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: "",
        }),
      ).toBe(false);
    });

    test("returns false when accessToken is undefined", () => {
      expect(
        shouldEmitNativeHandoff({
          refreshToken: "refresh",
          accessToken: undefined,
        }),
      ).toBe(false);
    });
  });
});
