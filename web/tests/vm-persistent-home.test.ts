import { describe, expect, test } from "bun:test";
import { homeVolumeNameForUser } from "../services/vms/workflows";

describe("persistent home volume naming", () => {
  test("is stable for the same user", () => {
    expect(homeVolumeNameForUser("user-1")).toBe(homeVolumeNameForUser("user-1"));
  });

  test("differs between users and never embeds the raw user id", () => {
    const a = homeVolumeNameForUser("user-1");
    const b = homeVolumeNameForUser("user-2");
    expect(a).not.toBe(b);
    expect(a).toMatch(/^cmux-home-[0-9a-f]{12}$/);
    expect(a).not.toContain("user-1");
  });
});
