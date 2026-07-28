import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import {
  DOWNLOAD_PLATFORMS,
  PLATFORM_DOWNLOADS,
  WAITLIST_PLATFORMS,
} from "../app/lib/download";
import sitemap from "../app/sitemap";
import middleware from "../proxy";
import en from "../messages/en.json";
import ja from "../messages/ja.json";

describe("Windows and Linux downloads", () => {
  test("uses the stable cmux-browser release asset names", () => {
    expect(DOWNLOAD_PLATFORMS).toEqual(["windows", "linux"]);
    expect(WAITLIST_PLATFORMS).toEqual(["android"]);

    expect(PLATFORM_DOWNLOADS.windows.primary.url).toBe(
      "https://github.com/manaflow-ai/cmux-browser/releases/latest/download/cmux-windows-x64-installer.exe",
    );
    expect(PLATFORM_DOWNLOADS.windows.portable.url).toBe(
      "https://github.com/manaflow-ai/cmux-browser/releases/latest/download/cmux-windows-x64.zip",
    );
    expect(PLATFORM_DOWNLOADS.linux.primary.url).toBe(
      "https://github.com/manaflow-ai/cmux-browser/releases/latest/download/cmux-linux-x64.deb",
    );
    expect(PLATFORM_DOWNLOADS.linux.portable.url).toBe(
      "https://github.com/manaflow-ai/cmux-browser/releases/latest/download/cmux-linux-x64.zip",
    );
  });

  test("keeps English and Japanese download copy in sync", () => {
    expect(messageShape(ja.browserDownloads)).toEqual(
      messageShape(en.browserDownloads),
    );
    expect(allStrings(en.browserDownloads).every(Boolean)).toBe(true);
    expect(allStrings(ja.browserDownloads).every(Boolean)).toBe(true);
  });

  test("publishes localized sitemap entries for both authored locales", () => {
    for (const path of ["/windows", "/linux"]) {
      const entries = sitemap().filter((entry) =>
        new URL(entry.url).pathname.endsWith(path),
      );

      expect(entries.map((entry) => new URL(entry.url).pathname)).toEqual([
        path,
        `/ja${path}`,
      ]);
      expect(entries.every((entry) => entry.lastModified === "2026-07-27")).toBe(
        true,
      );
    }
  });

  test("redirects unauthored localized routes to the canonical page", () => {
    for (const path of ["/windows", "/linux"]) {
      const response = middleware(
        new NextRequest(`https://cmux.com/de${path}`),
      );

      expect(response.status).toBe(301);
      expect(response.headers.get("location")).toBe(`https://cmux.com${path}`);
    }
  });
});

function allStrings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(allStrings);
  if (value && typeof value === "object") {
    return Object.values(value).flatMap(allStrings);
  }
  return [];
}

function messageShape(value: unknown): unknown {
  if (typeof value === "string") return "string";
  if (Array.isArray(value)) return value.map(messageShape);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [
        key,
        messageShape(nested),
      ]),
    );
  }
  return typeof value;
}
