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
    visibleEntryIds: ["connections.v1"],
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
      entryChannels: { "connections.v1": ["dev", "beta", "internal", "prod"] },
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
      entryChannels: { "connections.v2": ["beta"] },
    } as WhatsNewList;
    expect(() => validateList(list)).toThrow(
      "entryChannels key connections.v2 is not in visibleEntryIds",
    );
  });

  test("rejects unknown channel tokens (they fail closed on device)", () => {
    const list = {
      ...base,
      entryChannels: { "connections.v1": ["official"] },
    } as unknown as WhatsNewList;
    expect(() => validateList(list)).toThrow(/must be one of dev, beta, internal, demo, prod/);
  });

  test("rejects an empty channel list (hidden everywhere is a retraction, not targeting)", () => {
    const list: WhatsNewList = {
      ...base,
      entryChannels: { "connections.v1": [] },
    };
    expect(() => validateList(list)).toThrow(
      "entryChannels[connections.v1] must list at least one channel",
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
      entryChannels: { "connections.v1": ["beta", "beta"] },
    };
    expect(() => validateList(list)).toThrow(
      "entryChannels[connections.v1] contains duplicate channel beta",
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
});
