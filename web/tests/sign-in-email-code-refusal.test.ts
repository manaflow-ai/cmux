import { describe, expect, test } from "bun:test";
import { KnownError, KnownErrors } from "@hexclave/shared";
import en from "../messages/en.json";
import { emailCodeRefusal } from "../app/handler/sign-in-entry";

describe("email code refusal", () => {
  test("an existing account with an unverified email is told to use its sign-up method", () => {
    // The 409 the auth service returns, parsed the way the SDK parses it.
    const refused = KnownError.fromJson({
      code: "USER_EMAIL_ALREADY_EXISTS",
      message: "A user with email \"person@example.com\" already exists but the email is not verified.",
      details: { email: "person@example.com", would_work_if_email_was_verified: true },
    });
    expect(KnownErrors.UserWithEmailAlreadyExists.isInstance(refused)).toBe(true);
    expect(emailCodeRefusal(refused)).toBe("unverified-account");
  });

  test("an existing account that verifying would not help stays generic", () => {
    expect(emailCodeRefusal(new KnownErrors.UserWithEmailAlreadyExists("person@example.com", false))).toBe("generic");
  });

  test("disabled sign-up keeps its own message", () => {
    expect(emailCodeRefusal(new KnownErrors.SignUpNotEnabled())).toBe("sign-up-disabled");
  });

  test("anything else is generic", () => {
    expect(emailCodeRefusal(new Error("network"))).toBe("generic");
    expect(emailCodeRefusal(null)).toBe("generic");
    expect(emailCodeRefusal(new KnownErrors.UserNotFound())).toBe("generic");
  });

  test("the unverified-account copy exists in every catalog", async () => {
    const { readdir, readFile } = await import("node:fs/promises");
    const dir = new URL("../messages/", import.meta.url);
    const catalogs = (await readdir(dir)).filter((name) => name.endsWith(".json"));
    expect(catalogs.length).toBeGreaterThan(1);
    for (const name of catalogs) {
      const catalog = JSON.parse(await readFile(new URL(name, dir), "utf8")) as { cmuxSignIn: Record<string, unknown> };
      expect({ name, unverified: typeof catalog.cmuxSignIn.errorEmailUnverified, button: typeof catalog.cmuxSignIn.useEmailPasswordInstead })
        .toEqual({ name, unverified: "string", button: "string" });
    }
    expect(en.cmuxSignIn.errorEmailUnverified).not.toBe(en.cmuxSignIn.errorGeneric);
  });
});
