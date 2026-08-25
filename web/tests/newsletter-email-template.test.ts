import { describe, expect, test } from "bun:test";

// Structural guarantees on the marketing email templates: the shared layout
// always carries the Resend unsubscribe merge token and the CAN-SPAM
// physical postal address, and the greeting can never render empty or
// "undefined".

import { renderTemplate } from "../emails/render";
import {
  COMPANY_POSTAL_ADDRESS,
  RESEND_UNSUBSCRIBE_TOKEN,
} from "../emails/components/email-layout";
import { FIRST_NAME_GREETING_TOKEN } from "../emails/product-update";

describe("product-update template", () => {
  test("always renders the literal Resend unsubscribe token in the footer", async () => {
    const { html } = await renderTemplate("product-update");
    expect(html).toContain(RESEND_UNSUBSCRIBE_TOKEN);
    // The token must survive as an href, not get URL-mangled.
    expect(html).toContain(`href="${RESEND_UNSUBSCRIBE_TOKEN}"`);
  });

  test("greeting defaults to the merge tag with a 'there' fallback", async () => {
    const { html } = await renderTemplate("product-update");
    expect(html).toContain(FIRST_NAME_GREETING_TOKEN);
    // Resend's current broadcast merge-tag syntax with an explicit fallback,
    // so contacts without a stored name never see "Hey, ,".
    expect(FIRST_NAME_GREETING_TOKEN).toBe("{{{contact.first_name|there}}}");
  });

  test("opens with 'Hey, <name>. Austin from cmux here.', never 'undefined'", async () => {
    const { html } = await renderTemplate("product-update", {
      greetingName: "Austin",
    });
    expect(html).toContain("Hey, Austin. Austin from cmux here.");
    expect(html).not.toContain("undefined");
    expect(html).not.toContain("Hey, ,");
  });

  test("a whitespace-only greeting override falls back instead of 'Hey, ,'", async () => {
    const { html } = await renderTemplate("product-update", {
      greetingName: "   ",
    });
    expect(html).toContain(FIRST_NAME_GREETING_TOKEN);
    expect(html).not.toContain("Hey, ,");
  });

  test("always renders the CAN-SPAM physical postal address in the footer", async () => {
    const { html } = await renderTemplate("product-update");
    // Assert every address component (street, locality, region, zip) so a
    // partial footer cannot pass; the separator glyph may be HTML-escaped.
    expect(html).toContain(COMPANY_POSTAL_ADDRESS);
  });

  test("subject defaults to the headline and accepts an override", async () => {
    const defaulted = await renderTemplate("product-update");
    expect(defaulted.subject.length).toBeGreaterThan(0);
    const overridden = await renderTemplate("product-update", {
      subject: "Custom subject",
    });
    expect(overridden.subject).toBe("Custom subject");
  });

  test("renders cmux branding", async () => {
    const { html } = await renderTemplate("product-update");
    expect(html).toContain("Austin from cmux here.");
    expect(html).toContain("Manaflow, Inc.");
  });

  test("renders bullet lists inside a section when provided", async () => {
    const { html } = await renderTemplate("product-update");
    expect(html).toContain("Full agent session history, synced live from your Mac");
  });

  test("renders the selected locale catalog and lang attribute", async () => {
    const { html, subject } = await renderTemplate("product-update", {
      locale: "ja",
    });
    expect(html).toContain('<html lang="ja"');
    expect(html).toContain("cmux の Austin です");
    expect(html).not.toContain("Austin from cmux here.");
    expect(subject).toContain("cmux アップデート");
  });
});
