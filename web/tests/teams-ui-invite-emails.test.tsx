import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);

const {
  addEmailChips,
  isValidEmail,
  MAX_INVITE_EMAILS,
  removeEmailChip,
  sendableEmails,
  splitEmailInput,
} = await import("../app/[locale]/dashboard/teams/team-logic");
const { EmailChipInput } = await import("../app/[locale]/dashboard/teams/invite-panel");

describe("invite email chips", () => {
  test("splits pasted text on commas, semicolons, spaces, and newlines", () => {
    expect(splitEmailInput("a@x.com, b@x.com;c@x.com\nd@x.com\t e@x.com  ")).toEqual([
      "a@x.com",
      "b@x.com",
      "c@x.com",
      "d@x.com",
      "e@x.com",
    ]);
    expect(splitEmailInput("<angle@x.com>")).toEqual(["angle@x.com"]);
    expect(splitEmailInput(" ,, ")).toEqual([]);
  });

  test("validates addresses loosely", () => {
    expect(isValidEmail("dev@cmux.com")).toBe(true);
    expect(isValidEmail("dev@cmux")).toBe(false);
    expect(isValidEmail("dev.cmux.com")).toBe(false);
    expect(isValidEmail("a@b@c.com")).toBe(false);
  });

  test("keeps invalid chips visible, ignores case-insensitive duplicates", () => {
    const first = addEmailChips([], "Ann@x.com typo@nowhere");
    expect(first.chips).toEqual([
      { email: "Ann@x.com", valid: true },
      { email: "typo@nowhere", valid: false },
    ]);
    const second = addEmailChips(first.chips, "ann@X.com bob@x.com");
    expect(second.chips.map((chip) => chip.email)).toEqual(["Ann@x.com", "typo@nowhere", "bob@x.com"]);
    expect(second.overflow).toBe(0);
  });

  test("reports addresses beyond the per-request cap", () => {
    const pasted = Array.from({ length: MAX_INVITE_EMAILS + 3 }, (_, index) => `user${index}@x.com`).join("\n");
    const update = addEmailChips([], pasted);
    expect(update.chips).toHaveLength(MAX_INVITE_EMAILS);
    expect(update.overflow).toBe(3);
  });

  test("sends only when every chip is valid", () => {
    const { chips } = addEmailChips([], "a@x.com bad");
    expect(sendableEmails(chips)).toBeNull();
    expect(sendableEmails([])).toBeNull();
    expect(sendableEmails(removeEmailChip(chips, "bad"))).toEqual(["a@x.com"]);
  });

  test("renders invalid chips distinctly with a remove control", () => {
    const html = renderToStaticMarkup(
      <EmailChipInput
        chips={[
          { email: "ok@x.com", valid: true },
          { email: "nope", valid: false },
        ]}
        onChange={() => undefined}
      />,
    );
    expect(html).toContain("ok@x.com");
    expect(html).toContain('title="Not a valid email address"');
    expect(html).toContain('aria-label="Remove nope"');
  });
});
