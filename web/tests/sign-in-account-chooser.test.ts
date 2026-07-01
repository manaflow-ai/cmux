import { describe, expect, test } from "bun:test";
import {
  parseRememberedSignInAccounts,
  rememberSignInAccount,
  RECENT_SIGN_IN_ACCOUNTS_MAX,
} from "../app/handler/sign-in/recent-accounts";
import {
  preferredHandlerLocale,
  signInChooserMessages,
} from "../app/handler/sign-in/messages";

describe("sign-in account chooser", () => {
  test("parses remembered accounts defensively and sorts newest first", () => {
    const accounts = parseRememberedSignInAccounts(
      JSON.stringify([
        {
          id: "old",
          email: "OLD@EXAMPLE.COM",
          name: "Old",
          lastSeenAt: "2026-01-01T00:00:00.000Z",
        },
        {
          id: "new",
          email: "new@example.com",
          name: "New",
          lastSeenAt: "2026-02-01T00:00:00.000Z",
        },
        { email: "missing-id@example.com", name: "Missing" },
        null,
      ]),
    );

    expect(accounts.map((account) => account.id)).toEqual(["new", "old"]);
    expect(accounts[1].email).toBe("old@example.com");
    expect(parseRememberedSignInAccounts("{")).toEqual([]);
  });

  test("remembers the newest account once and caps the list", () => {
    const current = Array.from(
      { length: RECENT_SIGN_IN_ACCOUNTS_MAX },
      (_, index) => ({
        id: `u${index}`,
        email: `u${index}@example.com`,
        name: `User ${index}`,
        lastSeenAt: `2026-01-0${index + 1}T00:00:00.000Z`,
      }),
    );

    const remembered = rememberSignInAccount(
      current,
      { id: "replacement", email: "u1@example.com", name: "Replacement" },
      new Date("2026-03-01T00:00:00.000Z"),
    );

    expect(remembered).toHaveLength(RECENT_SIGN_IN_ACCOUNTS_MAX);
    expect(remembered[0]).toMatchObject({
      id: "replacement",
      email: "u1@example.com",
      name: "Replacement",
    });
    expect(remembered.some((account) => account.id === "u1")).toBe(false);
  });

  test("uses the best supported locale from accept-language", () => {
    expect(preferredHandlerLocale("fr-CA,fr;q=0.9,en;q=0.8")).toBe("fr");
    expect(preferredHandlerLocale("pt-BR,pt;q=0.9")).toBe("pt-BR");
    expect(preferredHandlerLocale("zz-ZZ")).toBe("en");
  });

  test("loads a localized generic sign-in failure message", async () => {
    const { messages } = await signInChooserMessages("en-US,en;q=0.9");

    expect(messages.signInFailed).toBe("Sign-in failed. Try again.");
    expect(messages.signInFailed).not.toBe(messages.continueAction);
  });
});
