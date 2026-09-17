import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DOWNLOAD_PLATFORMS,
  PLATFORM_DOWNLOADS,
  WAITLIST_PLATFORMS,
  platformMenuSectionsForAvailability,
} from "../app/lib/download";
import sitemap from "../app/sitemap";
import { locales } from "../i18n/routing";
import en from "../messages/en.json";

const MESSAGE_DIRECTORY = fileURLToPath(
  new URL("../messages/", import.meta.url),
);
const PLATFORM_PAGE_SOURCE = fileURLToPath(
  new URL(
    "../app/[locale]/(landing)/platform-download-page.tsx",
    import.meta.url,
  ),
);

describe("Windows and Linux downloads", () => {
  test("keeps unpublished platforms gated behind the waitlist", () => {
    expect(DOWNLOAD_PLATFORMS).toEqual([]);
    expect(WAITLIST_PLATFORMS).toEqual(["linux", "android", "windows"]);

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

  test("keeps direct links and waitlists coherent for every release state", () => {
    expect(
      platformMenuSectionsForAvailability({
        windows: false,
        linux: false,
      }),
    ).toEqual({
      downloads: [],
      waitlist: ["linux", "android", "windows"],
    });
    expect(
      platformMenuSectionsForAvailability({
        windows: true,
        linux: false,
      }),
    ).toEqual({
      downloads: ["windows"],
      waitlist: ["linux", "android"],
    });
    expect(
      platformMenuSectionsForAvailability({
        windows: false,
        linux: true,
      }),
    ).toEqual({
      downloads: ["linux"],
      waitlist: ["android", "windows"],
    });
    expect(
      platformMenuSectionsForAvailability({
        windows: true,
        linux: true,
      }),
    ).toEqual({
      downloads: ["windows", "linux"],
      waitlist: ["android"],
    });
  });

  test("keeps every locale's download copy complete and token-compatible", async () => {
    const englishLeaves = leafStrings(en.browserDownloads);

    for (const locale of locales) {
      const catalog = JSON.parse(
        await readFile(join(MESSAGE_DIRECTORY, `${locale}.json`), "utf8"),
      );
      const localizedLeaves = leafStrings(catalog.browserDownloads);

      expect(messageShape(catalog.browserDownloads)).toEqual(
        messageShape(en.browserDownloads),
      );
      expect(Object.keys(localizedLeaves)).toEqual(Object.keys(englishLeaves));
      for (const [key, english] of Object.entries(englishLeaves)) {
        const localized = localizedLeaves[key];
        expect(localized.length).toBeGreaterThan(0);
        expect(messageTokens(localized)).toEqual(messageTokens(english));
      }

      expect(messageTokens(catalog.home.faqPlatformA)).toEqual(
        messageTokens(en.home.faqPlatformA),
      );
      for (const availabilityNeutralMessage of [
        catalog.home.faqPlatformA,
        catalog.waitlist.descriptionAny,
        catalog.waitlist.calloutText,
      ]) {
        expect(availabilityNeutralMessage).not.toMatch(/\b(?:Linux|Windows)\b/u);
      }
    }
  });

  test("keeps unavailable platform pages out of the sitemap", () => {
    for (const path of ["/windows", "/linux"]) {
      expect(
        sitemap().filter((entry) =>
          new URL(entry.url).pathname.endsWith(path),
        ),
      ).toEqual([]);
    }
  });

  test("wraps long localized installer labels on narrow screens", async () => {
    const source = await readFile(PLATFORM_PAGE_SOURCE, "utf8");
    expect(source).toContain("w-full max-w-full justify-center sm:w-auto");
    expect(source).toContain(
      "min-w-0 text-balance whitespace-normal text-center",
    );
    expect(source).toContain('className="shrink-0"');
  });
});

/** Flattens a nested message namespace into dot-path string leaves. */
function leafStrings(
  value: unknown,
  prefix = "",
): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return Object.fromEntries(
    Object.entries(value).flatMap(([key, nested]) => {
      const path = prefix ? `${prefix}.${key}` : key;
      if (typeof nested === "string") return [[path, nested]];
      return Object.entries(leafStrings(nested, path));
    }),
  );
}

/** Extracts ICU placeholders and rich-text tags for locale parity checks. */
function messageTokens(value: string): string[] {
  return Array.from(
    value.matchAll(
      /(?:\{[A-Za-z][A-Za-z0-9_]*\}|<\/?[A-Za-z][A-Za-z0-9_]*>)/gu,
    ),
    (match) => match[0],
  ).sort();
}

/** Describes a message namespace without depending on translated values. */
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
