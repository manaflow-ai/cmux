import { describe, expect, test } from "bun:test";
import { isPrivateSharePath, isPrivateShareURL } from "../services/share/privacy";

describe("workspace share analytics privacy", () => {
  test("matches only the private share route tree", () => {
    expect(isPrivateSharePath("/share")).toBe(true);
    expect(isPrivateSharePath("/share/AbCdEfGhIjKlMnOpQrSt_-")).toBe(true);
    expect(isPrivateSharePath("/sharing")).toBe(false);
    expect(isPrivateSharePath("/en/share/AbCdEfGhIjKlMnOpQrSt_-")).toBe(false);
  });

  test("recognizes queued analytics events carrying a share URL", () => {
    expect(isPrivateShareURL("https://cmux.com/share/AbCdEfGhIjKlMnOpQrSt_-")).toBe(true);
    expect(isPrivateShareURL("/share/AbCdEfGhIjKlMnOpQrSt_-")).toBe(true);
    expect(isPrivateShareURL("https://cmux.com/docs")).toBe(false);
    expect(isPrivateShareURL(null)).toBe(false);
  });
});
