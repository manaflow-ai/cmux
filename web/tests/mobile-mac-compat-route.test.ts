import { describe, expect, test } from "bun:test";

import {
  mobileMacCompatList,
  type MobileMacCompatList,
} from "../data/mobile-mac-compat";

const { GET, OPTIONS, validateList } = await import(
  "../app/api/mobile-mac-compat/route"
);

/**
 * The compat list gates whether cmux iOS accepts a connected Mac, so the
 * route must validate it at build time: a malformed version, an unordered
 * tier list, or a download URL off cmux-owned hosts would otherwise ship to
 * every device that fetches the list.
 */
describe("mobile-mac-compat route", () => {
  const base: MobileMacCompatList = {
    downloads: {
      stable:
        "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg",
      nightly: "https://github.com/manaflow-ai/cmux/releases/tag/nightly",
    },
    entries: [
      {
        minIOSVersion: "1.0.4",
        stableMinVersion: "0.64.23",
        nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
      },
    ],
  };

  test("serves the checked-in list with the caching and CORS headers", async () => {
    const response = await GET(
      new Request("https://cmux.test/api/mobile-mac-compat"),
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe(
      "application/json; charset=utf-8",
    );
    expect(response.headers.get("Cache-Control")).toBe(
      "public, s-maxage=300, stale-while-revalidate=86400",
    );
    expect(response.headers.get("ETag")).toMatch(/^".+"$/);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Methods")).toBe(
      "GET, OPTIONS",
    );
    expect(response.headers.get("Access-Control-Allow-Headers")).toBe(
      "If-None-Match, Content-Type",
    );
    const payload = (await response.json()) as MobileMacCompatList;
    expect(payload).toEqual(mobileMacCompatList);
  });

  test("returns 304 for a matching If-None-Match", async () => {
    const first = await GET(
      new Request("https://cmux.test/api/mobile-mac-compat"),
    );
    const etag = first.headers.get("ETag");
    expect(etag).toBeTruthy();
    const second = await GET(
      new Request("https://cmux.test/api/mobile-mac-compat", {
        headers: { "If-None-Match": etag as string },
      }),
    );
    expect(second.status).toBe(304);
    expect(await second.text()).toBe("");
    expect(second.headers.get("ETag")).toBe(etag);
  });

  test("OPTIONS returns 204 with the CORS headers", async () => {
    const response = OPTIONS();
    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(response.headers.get("Access-Control-Allow-Methods")).toBe(
      "GET, OPTIONS",
    );
    expect(response.headers.get("Access-Control-Allow-Headers")).toBe(
      "If-None-Match, Content-Type",
    );
  });

  test("accepts the committed data", () => {
    expect(validateList(mobileMacCompatList)).toEqual(mobileMacCompatList);
  });

  test("accepts a tier without a nightly requirement and multiple ascending tiers", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.0.4", stableMinVersion: "0.64.23" },
        {
          minIOSVersion: "1.1",
          stableMinVersion: "0.65.0",
          nightly: { minBaseVersion: "0.65.0", minBuild: "3345650013300" },
        },
      ],
    };
    expect(validateList(list)).toEqual(list);
  });

  test("rejects empty entries", () => {
    const list: MobileMacCompatList = { ...base, entries: [] };
    expect(() => validateList(list)).toThrow(
      "entries must list at least one tier",
    );
  });

  test("rejects malformed version strings", () => {
    const badIOS: MobileMacCompatList = {
      ...base,
      entries: [{ minIOSVersion: "1.0.4-beta", stableMinVersion: "0.64.23" }],
    };
    expect(() => validateList(badIOS)).toThrow(
      "entries[0].minIOSVersion must be a dotted numeric version, got 1.0.4-beta",
    );
    const badStable: MobileMacCompatList = {
      ...base,
      entries: [{ minIOSVersion: "1.0.4", stableMinVersion: "v0.64.23" }],
    };
    expect(() => validateList(badStable)).toThrow(
      "entries[0].stableMinVersion must be a dotted numeric version, got v0.64.23",
    );
    const badNightlyBase: MobileMacCompatList = {
      ...base,
      entries: [
        {
          minIOSVersion: "1.0.4",
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.", minBuild: "3345650013202" },
        },
      ],
    };
    expect(() => validateList(badNightlyBase)).toThrow(
      "entries[0].nightly.minBaseVersion must be a dotted numeric version, got 0.64.",
    );
  });

  test("rejects a minBuild with non-digits", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        {
          minIOSVersion: "1.0.4",
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "33456500132a2" },
        },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[0].nightly.minBuild must be digits only, got 33456500132a2",
    );
  });

  test("rejects a minBuild with a leading zero (breaks numeric string-length compare)", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        {
          minIOSVersion: "1.0.4",
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "03345650013202" },
        },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[0].nightly.minBuild must not have a leading zero, got 03345650013202",
    );
  });

  test("rejects a four-component version the client cannot parse", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [{ minIOSVersion: "1.0.0.1", stableMinVersion: "0.64.23" }],
    };
    expect(() => validateList(list)).toThrow(
      "entries[0].minIOSVersion must be a dotted numeric version, got 1.0.0.1",
    );
  });

  test("accepts a bounded tier range and a pinpoint range", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.0", maxIOSVersion: "1.0.99", stableMinVersion: "0.64.23" },
        { minIOSVersion: "1.1", maxIOSVersion: "1.1", stableMinVersion: "0.65.0" },
      ],
    };
    expect(() => validateList(list)).not.toThrow();
  });

  test("rejects an inverted tier range", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.1", maxIOSVersion: "1.0.9", stableMinVersion: "0.64.23" },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[0] range is empty: minIOSVersion 1.1 exceeds maxIOSVersion 1.0.9",
    );
  });

  test("rejects a malformed maxIOSVersion", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.0", maxIOSVersion: "1.0.x", stableMinVersion: "0.64.23" },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[0].maxIOSVersion must be a dotted numeric version, got 1.0.x",
    );
  });

  test("rejects out-of-order tiers", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.1", stableMinVersion: "0.65.0" },
        { minIOSVersion: "1.0.4", stableMinVersion: "0.64.23" },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[1].minIOSVersion 1.0.4 must be strictly greater than 1.1",
    );
  });

  test("rejects duplicate minIOSVersion tiers", () => {
    const list: MobileMacCompatList = {
      ...base,
      entries: [
        { minIOSVersion: "1.0.4", stableMinVersion: "0.64.23" },
        { minIOSVersion: "1.0.4", stableMinVersion: "0.64.24" },
      ],
    };
    expect(() => validateList(list)).toThrow(
      "entries[1].minIOSVersion 1.0.4 must be strictly greater than 1.0.4",
    );
  });

  test("rejects an http download URL", () => {
    const list: MobileMacCompatList = {
      ...base,
      downloads: {
        ...base.downloads,
        stable: "http://github.com/manaflow-ai/cmux/releases",
      },
    };
    expect(() => validateList(list)).toThrow("downloads.stable must use https");
  });

  test("rejects a download URL on a foreign host", () => {
    const list: MobileMacCompatList = {
      ...base,
      downloads: {
        ...base.downloads,
        nightly: "https://example.com/cmux-nightly.dmg",
      },
    };
    expect(() => validateList(list)).toThrow(
      "downloads.nightly must be on a cmux-owned or cmux-release host, got example.com",
    );
  });

  test("rejects values with surrounding whitespace", () => {
    const paddedVersion: MobileMacCompatList = {
      ...base,
      entries: [{ minIOSVersion: " 1.0.4", stableMinVersion: "0.64.23" }],
    };
    expect(() => validateList(paddedVersion)).toThrow(
      "entries[0].minIOSVersion must not have leading or trailing whitespace",
    );
    const paddedURL: MobileMacCompatList = {
      ...base,
      downloads: { ...base.downloads, nightly: `${base.downloads.nightly} ` },
    };
    expect(() => validateList(paddedURL)).toThrow(
      "downloads.nightly must not have leading or trailing whitespace",
    );
  });
});
