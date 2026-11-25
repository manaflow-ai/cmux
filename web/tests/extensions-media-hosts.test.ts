import { describe, expect, test } from "bun:test";
import { isMediaUrl } from "../app/extensions/_lib/media-hosts";

describe("the OG card fetches listing media only from registry raw-file hosts", () => {
  test("accepts the URLs the registry builds", () => {
    expect(isMediaUrl("https://raw.githubusercontent.com/o/r/0123456789abcdef0123456789abcdef01234567/icon.png")).toBe(true);
    expect(isMediaUrl("https://gitlab.com/o/r/-/raw/0123456789abcdef0123456789abcdef01234567/icon.png")).toBe(true);
    expect(isMediaUrl("https://codeberg.org/o/r/raw/commit/0123456789abcdef0123456789abcdef01234567/icon.png")).toBe(true);
  });

  test("refuses private, loopback and other destinations", () => {
    for (const url of [
      "https://127.0.0.1/icon.png",
      "https://localhost/icon.png",
      "https://10.0.0.5/icon.png",
      "https://169.254.169.254/latest/meta-data",
      "https://[::1]/icon.png",
      "https://internal.example.com/icon.png",
      "https://raw.githubusercontent.com.evil.test/icon.png",
      "https://raw.githubusercontent.com:8443/o/r/sha/icon.png",
      "https://user:pass@raw.githubusercontent.com/o/r/sha/icon.png",
      "http://raw.githubusercontent.com/o/r/sha/icon.png",
      "not a url",
    ]) {
      expect(isMediaUrl(url)).toBe(false);
    }
  });
});
