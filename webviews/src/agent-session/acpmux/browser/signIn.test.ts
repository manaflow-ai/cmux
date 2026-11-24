// The browser sign-in screen names each refusal the daemon sends (`browser.sign_in.*`,
// `signin.unconfigured`) and the socket's own (`signin.unreachable` and kin); anything else
// falls back to the generic line rather than showing a raw reason.
import { describe, expect, test } from "bun:test";
import { signInReasonKey } from "./BrowserSignIn";
import { signInError } from "./signInWire";

describe("signInReasonKey", () => {
  test("maps daemon and socket reasons", () => {
    expect(signInReasonKey("signin.unconfigured")).toBe("browserSignIn.error.unconfigured");
    expect(signInReasonKey("browser.sign_in.code_refused")).toBe("browserSignIn.error.code");
    expect(signInReasonKey("browser.sign_in.rate_limited")).toBe("browserSignIn.error.rateLimited");
    expect(signInReasonKey("browser.sign_in.account_mismatch")).toBe("browserSignIn.error.account");
    expect(signInReasonKey("signin.unreachable")).toBe("browserSignIn.error.unreachable");
  });
  test("unknown or missing reasons are generic", () => {
    expect(signInReasonKey(undefined)).toBe("browserSignIn.error.generic");
    expect(signInReasonKey("toString")).toBe("browserSignIn.error.generic");
    expect(signInReasonKey("nope")).toBe("browserSignIn.error.generic");
  });
  test("signInError carries its reason", () => {
    const e = signInError("signin.timeout", "slow");
    expect(e.reason).toBe("signin.timeout");
    expect(e).toBeInstanceOf(Error);
  });
});
