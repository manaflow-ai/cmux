import { describe, expect, test } from "bun:test";
import { shareUserFromStackPayload } from "../src/auth";

const verifiedUser = {
  id: "user-1",
  primary_email: "person@example.com",
  primary_email_verified: true,
  display_name: "Person",
};

describe("workspace share host authentication", () => {
  test("rejects anonymous and restricted Stack identities in both API shapes", () => {
    expect(shareUserFromStackPayload({ ...verifiedUser, is_anonymous: true })).toBeNull();
    expect(shareUserFromStackPayload({ ...verifiedUser, isAnonymous: true })).toBeNull();
    expect(shareUserFromStackPayload({ ...verifiedUser, is_restricted: true })).toBeNull();
    expect(shareUserFromStackPayload({ ...verifiedUser, isRestricted: true })).toBeNull();
    expect(shareUserFromStackPayload(verifiedUser)?.id).toBe("user-1");
  });

  test("normalizes host display names before broadcasting them", () => {
    expect(shareUserFromStackPayload({
      ...verifiedUser,
      display_name: "Person\nVerified email: attacker@example.com\u202E\u2066",
    })?.displayName).toBe("Person Verified email: attacker@example.com");
  });
});
