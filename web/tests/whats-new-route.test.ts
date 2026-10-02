import { describe, expect, test } from "bun:test";

import { whatsNewList, type WhatsNewList } from "../data/whats-new";

const { GET, validateList } = await import("../app/api/whats-new/route");

/**
 * Channel targeting for What's New (Guideline 2.2, submission 591a59e6):
 * the served list may carry per-entry `entryChannels` and per-announcement
 * `channels` so specific content can be opted into the official App Store
 * channel ("prod") remotely; everything else defaults on device to the team
 * lanes only. The route must validate those lists at build time because an
 * unknown or empty channel list fails closed (invisible) on device.
 */
describe("whats-new route channel targeting", () => {
  const base: WhatsNewList = {
    visibleEntryIds: ["connections.v2"],
    announcements: [],
  };
  const announcement = {
    id: "service.notice",
    minVersion: "1.0",
    maxVersion: "2.0",
    title: "Service notice",
    features: [{ title: "News", detail: "Something changed." }],
  };

  test("serves the checked-in list, which keeps every entry off the official channel by default", async () => {
    const response = await GET(new Request("https://cmux.test/api/whats-new"));
    expect(response.status).toBe(200);
    const payload = (await response.json()) as WhatsNewList;
    expect(payload).toEqual(whatsNewList);
    expect(payload.visibleEntryIds).toEqual(["pairing.1.0.6", "connections.v2", "connections.v1"]);
    // The rejection-driven contract: no checked-in entry or announcement may
    // silently target the official app; reaching "prod" must be a reviewed,
    // explicit channel list. If this assertion fails, someone opted content
    // into the App Store app — make sure that is deliberate.
    for (const [entryId, channels] of Object.entries(payload.entryChannels ?? {})) {
      expect(channels).toBeDefined();
      if (channels?.includes("prod")) {
        throw new Error(
          `entryChannels[${entryId}] targets the official channel; this test exists so that is a conscious edit`,
        );
      }
    }
    for (const entry of payload.announcements) {
      expect(entry.channels?.includes("prod") ?? false).toBe(false);
    }
  });

  test("accepts a valid per-entry channel override including prod", () => {
    const list: WhatsNewList = {
      ...base,
      entryChannels: { "connections.v2": ["dev", "beta", "internal", "prod"] },
    };
    expect(validateList(list)).toEqual(list);
  });

  test("accepts an announcement with an explicit channel list", () => {
    const list: WhatsNewList = {
      ...base,
      announcements: [{ ...announcement, channels: ["prod"] }],
    };
    expect(validateList(list)).toEqual(list);
  });

  test("rejects an entryChannels key that is not a visible entry", () => {
    const list = {
      ...base,
      entryChannels: { "connections.v1": ["beta"] },
    } as WhatsNewList;
    expect(() => validateList(list)).toThrow(
      "entryChannels key connections.v1 is not in visibleEntryIds",
    );
  });

  test("rejects unknown channel tokens (they fail closed on device)", () => {
    const list = {
      ...base,
      entryChannels: { "connections.v2": ["official"] },
    } as unknown as WhatsNewList;
    expect(() => validateList(list)).toThrow(/must be one of dev, beta, internal, demo, prod/);
  });

  test("rejects an empty channel list (hidden everywhere is a retraction, not targeting)", () => {
    const list: WhatsNewList = {
      ...base,
      entryChannels: { "connections.v2": [] },
    };
    expect(() => validateList(list)).toThrow(
      "entryChannels[connections.v2] must list at least one channel",
    );
    const announcementList: WhatsNewList = {
      ...base,
      announcements: [{ ...announcement, channels: [] }],
    };
    expect(() => validateList(announcementList)).toThrow(
      "announcements[0].channels must list at least one channel",
    );
  });

  test("rejects duplicate channels", () => {
    const list: WhatsNewList = {
      ...base,
      entryChannels: { "connections.v2": ["beta", "beta"] },
    };
    expect(() => validateList(list)).toThrow(
      "entryChannels[connections.v2] contains duplicate channel beta",
    );
  });

  test("rejects an unknown announcement channel token", () => {
    const list = {
      ...base,
      announcements: [{ ...announcement, channels: ["testflight"] }],
    } as unknown as WhatsNewList;
    expect(() => validateList(list)).toThrow(/announcements\[0\]\.channels\[0\] must be one of/);
  });

  test("still accepts the legacy shape with no channel fields", () => {
    expect(validateList(base)).toEqual(base);
  });

  test("ships the 1.0.6 connection notice only to beta and internal", () => {
    const notice = whatsNewList.announcements.find(
      (entry) => entry.id === "ios-1.0.6-connections",
    );
    expect(notice).toEqual({
      id: "ios-1.0.6-connections",
      minVersion: "1.0.6",
      maxVersion: "1.0.6",
      title: "What's New in 1.0.6",
      releaseLabel: "1.0.6 · September 2026",
      channels: ["beta", "internal"],
      localizations: expect.objectContaining({ en: expect.objectContaining({ title: "What's New in 1.0.6" }) }),
      features: expect.arrayContaining([
        expect.objectContaining({
          title: "Updated Mac connections",
        }),
        expect.objectContaining({
          detail: expect.stringContaining("0.64.25-nightly.3522337919701"),
        }),
      ]),
    });
  });

  test("serves translated release instructions with exact compatibility values", async () => {
    const response = await GET(new Request("https://cmux.test/api/whats-new"));
    const payload = await response.json() as WhatsNewList;
    const notice = payload.announcements.find((entry) => entry.id === "ios-1.0.6-connections")!;
    const translations = notice.localizations!;
    expect(Object.keys(translations).sort()).toEqual([
      "ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km", "ko", "no",
      "pl", "pt-BR", "ru", "th", "tr", "uk", "zh-CN", "zh-TW",
    ]);
    for (const [locale, content] of Object.entries(translations)) {
      expect(content.features[1].detail).toContain("0.64.25-nightly.3522337919701");
      expect(content.features[2].detail).toContain("1.0.5 (20260914204800)");
      expect(JSON.stringify(content)).not.toMatch(/\{(?:stableVersion|nightlyVersion|rollbackBuild)\}/);
      if (locale !== "en") expect(content.features[2].detail).not.toBe(translations.en.features[2].detail);
    }
  });

  test("rejects incomplete translated release instructions", () => {
    expect(() => validateList({
      ...base,
      announcements: [{ ...announcement, localizations: { ja: { title: "お知らせ", features: [] } } }],
    })).toThrow("localizations[ja].features must not be empty");
  });

});
