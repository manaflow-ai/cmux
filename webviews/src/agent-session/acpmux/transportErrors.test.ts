import { describe, expect, test } from "bun:test";
import { setPaneLanguage } from "./i18n";
import { NativeError } from "./nativeError";
import { errorMessage } from "./transportErrors";

/// The pane-native transport's refusals read as pane text, chosen by the error code (never by
/// the message), in the pane's language.
describe("transport refusals", () => {
  const rpc = (code: string) => Object.assign(new Error("Refused by the cmux host"), { code });

  test("each transport code has its own text, from a JSON-RPC refusal or a native reply", () => {
    setPaneLanguage("en");
    expect(errorMessage(rpc("transport.gesture_required"))).toBe("Click the choice again to apply it.");
    expect(errorMessage(rpc("transport.path_outside_roots"))).toBe(
      "This folder is outside the folders this pane may use.",
    );
    expect(errorMessage(rpc("transport.session_not_in_pane"))).toBe("This chat is not open in this pane.");
    expect(errorMessage(new NativeError({ code: "transport.intent_invalid", userMessage: "x" }))).toBe(
      "The pane sent a request the app does not accept.",
    );
  });

  test("the text follows the pane's language", () => {
    setPaneLanguage("ja");
    expect(errorMessage(rpc("transport.gesture_required"))).not.toBe("Click the choice again to apply it.");
    setPaneLanguage("en");
  });

  test("any other error keeps its own message; a message that only looks like a code is not mapped", () => {
    expect(errorMessage(rpc("validation.invalid"))).toBe("Refused by the cmux host");
    expect(errorMessage(new Error("transport.gesture_required"))).toBe("transport.gesture_required");
    expect(errorMessage("plain")).toBe("plain");
    expect(errorMessage(undefined)).toBe("");
  });
});
