import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "bun:test";

import { campaignCatalog, type Campaign } from "../data/campaigns";

const { GET, OPTIONS, validateCampaignCatalog } = await import("../app/api/campaigns/route");

const validCampaign: Campaign = {
  id: "sample-launch",
  template: "sheet",
  platforms: ["ios"],
  minAppVersion: "1.0.5",
  maxAppVersion: "2.0",
  startsAt: "2026-08-01T00:00:00.000Z",
  endsAt: "2026-12-01T00:00:00.000Z",
  rolloutPercent: 50,
  priority: 10,
  reshowPolicy: "once",
  showInWhatsNew: true,
  title: { en: "New in cmux", ja: "cmux の新機能" },
  body: { en: "Try the new thing.", ja: "新機能をお試しください。" },
  image: { light: "/campaigns/sample.png", aspectRatio: 2 },
  accentColor: "#5B8DEF",
  buttons: [
    {
      label: { en: "Learn more", ja: "詳細を見る" },
      action: { type: "openURL", url: "https://cmux.com/changelog" },
    },
    {
      label: { en: "Not now", ja: "あとで" },
      action: { type: "dismiss" },
      role: "secondary",
    },
  ],
};

function catalogWith(...campaigns: unknown[]): unknown {
  return { schemaVersion: 1, updatedAt: "2026-08-21T00:00:00.000Z", campaigns };
}

describe("campaigns route", () => {
  test("serves the checked-in catalog with cache, CORS, and a strong ETag", async () => {
    const response = await GET(new Request("https://cmux.test/api/campaigns"));
    const payload = JSON.stringify(validateCampaignCatalog(campaignCatalog));
    const expectedEtag = `"${createHash("sha256").update(payload).digest("base64url")}"`;

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("public, s-maxage=300, stale-while-revalidate=86400");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("etag")).toBe(expectedEtag);
    expect(await response.json()).toEqual(JSON.parse(payload));
  });

  test("returns 304 for a matching If-None-Match", async () => {
    const initial = await GET(new Request("https://cmux.test/api/campaigns"));
    const etag = initial.headers.get("etag");
    expect(etag).toBeTruthy();

    const revalidated = await GET(new Request("https://cmux.test/api/campaigns", {
      headers: { "If-None-Match": etag ?? "" },
    }));
    expect(revalidated.status).toBe(304);
    expect(await revalidated.text()).toBe("");
  });

  test("answers CORS preflight for public GET access", () => {
    const response = OPTIONS();
    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, OPTIONS");
  });

  test("accepts a fully populated campaign", () => {
    const normalized = validateCampaignCatalog(catalogWith(validCampaign));
    expect(normalized.campaigns).toHaveLength(1);
    expect(normalized.campaigns[0]).toMatchObject({ id: "sample-launch", template: "sheet" });
  });

  test("rejects malformed campaigns with the failing path in the error", () => {
    const cases: Array<{ patch: Partial<Campaign> | Record<string, unknown>; message: RegExp }> = [
      { patch: { id: "Bad_Slug" }, message: /id must be a kebab-case slug/ },
      { patch: { template: "toast" }, message: /template must be one of/ },
      { patch: { platforms: [] }, message: /platforms must be a nonempty array/ },
      { patch: { reshowPolicy: "always" }, message: /reshowPolicy/ },
      { patch: { minAppVersion: "v1.2" }, message: /dotted numeric version/ },
      { patch: { startsAt: "2026-08-01" }, message: /ISO-8601 instant with a timezone/ },
      { patch: { startsAt: "2026-12-01T00:00:00.000Z", endsAt: "2026-08-01T00:00:00.000Z" }, message: /endsAt must be after startsAt/ },
      { patch: { rolloutPercent: 150 }, message: /rolloutPercent/ },
      { patch: { title: { en: "English only" } }, message: /title\.ja/ },
      { patch: { body: { en: "", ja: "本文" } }, message: /body\.en/ },
      { patch: { accentColor: "blue" }, message: /accentColor/ },
      { patch: { image: { light: "ftp://cmux.com/x.png" } }, message: /https URL or a \/campaigns/ },
      {
        patch: {
          buttons: [
            { label: { en: "A", ja: "あ" }, action: { type: "dismiss" } },
            { label: { en: "B", ja: "い" }, action: { type: "dismiss" } },
            { label: { en: "C", ja: "う" }, action: { type: "dismiss" } },
          ],
        },
        message: /at most 2/,
      },
      {
        patch: {
          buttons: [{ label: { en: "Go", ja: "行く" }, action: { type: "openURL", url: "http://cmux.com" } }],
        },
        message: /url must be https/,
      },
    ];

    for (const { patch, message } of cases) {
      expect(() => validateCampaignCatalog(catalogWith({ ...validCampaign, ...patch })))
        .toThrow(message);
    }
  });

  test("rejects duplicate campaign ids", () => {
    expect(() => validateCampaignCatalog(catalogWith(validCampaign, validCampaign)))
      .toThrow(/duplicates id sample-launch/);
  });

  test("rejects unknown schema versions", () => {
    expect(() => validateCampaignCatalog({ ...campaignCatalog, schemaVersion: 2 }))
      .toThrow(/schemaVersion/);
  });

  test("every site-relative image in the shipped catalog exists in web/public", () => {
    for (const campaign of campaignCatalog.campaigns) {
      for (const url of [campaign.image?.light, campaign.image?.dark]) {
        if (!url || !url.startsWith("/")) continue;
        const file = fileURLToPath(new URL(`../public${url}`, import.meta.url));
        expect(existsSync(file)).toBe(true);
      }
    }
  });
});
