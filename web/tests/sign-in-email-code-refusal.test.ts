import { describe, expect, test } from "bun:test";
import { KnownError, KnownErrors } from "@hexclave/shared";
import en from "../messages/en.json";
import { emailCodeRefusal, signUpRefusal, withRefusalCode } from "../app/handler/sign-in-entry";

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

describe("refusal code on the generic message", () => {
  const generic = en.cmuxSignIn.errorGeneric;

  test("a refusal from the auth service names its code, so the failure can be told apart", () => {
    expect(withRefusalCode(generic, new KnownErrors.BotChallengeFailed("challenge failed"))).toBe(`${generic} (BOT_CHALLENGE_FAILED)`);
  });

  test("an error with no service code keeps the plain message", () => {
    expect(withRefusalCode(generic, new Error("network"))).toBe(generic);
    expect(withRefusalCode(generic, null)).toBe(generic);
  });

  test("only a code is shown: never free text the service or SDK wrote", () => {
    expect(withRefusalCode(generic, { errorCode: "Please update your SDK vendor" })).toBe(generic);
  });
});

describe("password sign-up refusal", () => {
  test("an email already in use is the answer the auth service really gives, and reads as an existing account", () => {
    // The 409 production returns for an email that already has an account.
    const refused = KnownError.fromJson({
      code: "CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE",
      message: "This email is already used for authentication by another account.",
      details: { type: "email", contact_channel_value: "person@example.com", would_work_if_email_was_verified: false },
    });
    expect(signUpRefusal(refused)).toBe("account-exists");
  });

  test("the older existing-account answer stays an existing account", () => {
    expect(signUpRefusal(new KnownErrors.UserWithEmailAlreadyExists("person@example.com", false))).toBe("account-exists");
  });

  test("disabled sign-up keeps its own message, and the rest are generic", () => {
    expect(signUpRefusal(new KnownErrors.SignUpNotEnabled())).toBe("sign-up-disabled");
    expect(signUpRefusal(new Error("network"))).toBe("generic");
    expect(signUpRefusal(null)).toBe("generic");
  });
});

describe("refusal code never says an account exists", () => {
  const generic = en.cmuxSignIn.errorGeneric;

  test.each([
    "USER_EMAIL_ALREADY_EXISTS",
    "CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE",
    "USER_NOT_FOUND",
    "EMAIL_PASSWORD_MISMATCH",
  ])("%s stays off the screen", (errorCode) => {
    expect(withRefusalCode(generic, { errorCode })).toBe(generic);
  });
});
