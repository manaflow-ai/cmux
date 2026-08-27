import { describe, expect, test } from "bun:test";

// Structural guarantees on the founders feedback-call template: same
// unsubscribe/footer guarantees as product-update (inherited from the
// shared layout), the correct booking link, and a never-empty greeting.

import { renderTemplate } from "../emails/render";
import { RESEND_UNSUBSCRIBE_TOKEN } from "../emails/components/email-layout";
import { FIRST_NAME_GREETING_TOKEN } from "../emails/founders-feedback-call";

describe("founders-feedback-call template", () => {
  test("always renders the literal Resend unsubscribe token in the footer", async () => {
    const { html } = await renderTemplate("founders-feedback-call");
    expect(html).toContain(RESEND_UNSUBSCRIBE_TOKEN);
    expect(html).toContain(`href="${RESEND_UNSUBSCRIBE_TOKEN}"`);
  });

  test("greeting defaults to the merge tag with a 'there' fallback", async () => {
    const { html } = await renderTemplate("founders-feedback-call");
    expect(html).toContain(FIRST_NAME_GREETING_TOKEN);
    expect(FIRST_NAME_GREETING_TOKEN).toBe("{{{contact.first_name|there}}}");
  });

  test("greeting override renders a concrete name, never 'undefined'", async () => {
    const { html } = await renderTemplate("founders-feedback-call", {
      greetingName: "Austin",
    });
    expect(html).toContain("Hey, Austin. Austin here.");
    expect(html).not.toContain("undefined");
    expect(html).not.toContain("Hey, ,");
  });

  test("links to the corrected booking URL, not a stale one", async () => {
    const { html } = await renderTemplate("founders-feedback-call");
    expect(html).toContain("https://calendar.app.google/usRQUbktHPuVTzNbA");
    expect(html).not.toContain("X4L17geibS5Nzd8t5");
  });

  test("mentions Founder's Edition priority", async () => {
    const { html } = await renderTemplate("founders-feedback-call");
    expect(html).toContain("Founder&#x27;s Edition");
    expect(html).toContain("priority");
  });

  test("signs off as Austin Wang", async () => {
    const { html } = await renderTemplate("founders-feedback-call");
    expect(html).toContain("Austin Wang");
  });

  test("interpolates the release version into the default subject", async () => {
    const english = await renderTemplate("founders-feedback-call");
    expect(english.subject).toBe("Help shape cmux 0.65.0");
    const japanese = await renderTemplate("founders-feedback-call", {
      locale: "ja",
    });
    expect(japanese.subject).toContain("cmux 0.65.0");
    expect(japanese.subject).not.toContain("{releaseVersion}");
  });
});
