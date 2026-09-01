import { describe, expect, test } from "bun:test";

import {
  EMAIL_SUBJECT,
  FOUNDER_CC,
  PRO_EMAIL_SUBJECT,
  REPLY_TO,
  buildFoundersWelcomeEmail,
  buildProWelcomeEmail,
  foundersThreadRef,
} from "../app/api/stripe/founders-welcome/welcome-email";
import {
  welcomeTriggerForCheckout,
  welcomeTriggerForMetadata,
} from "../app/api/stripe/founders-welcome/welcome-trigger";

// Regression coverage for the Founder's Edition welcome email collapsing into a
// single Gmail conversation. Gmail threads messages that share a normalized
// subject among the same participants, and every welcome uses the same subject
// + from + cc, so without a unique per-message discriminator all welcomes stack
// into one thread in austin@ and lawrence@'s inboxes (they are CC'd on every
// send). The fix attaches a unique X-Entity-Ref-ID per subscription, keyed to
// the Stripe checkout session id so it stays stable across Stripe's
// at-least-once redelivery (idempotent re-send) yet differs across
// subscriptions (new thread each).
const THREAD_HEADER = "X-Entity-Ref-ID";

const baseParams = {
  from: "Austin Wang <austin@manaflow.ai>",
  customerName: "Sample Buyer",
} as const;

// The route uses this classification to choose the personal welcome subject;
// explicit founder metadata wins if both shapes are present.
describe("welcomeTriggerForMetadata", () => {
  test("founders payment-link metadata classifies as founders_edition", () => {
    expect(welcomeTriggerForMetadata({ founders_edition: "true" })).toBe(
      "founders_edition",
    );
  });

  test("cmux Pro checkout metadata classifies as pro_plan (no founders key)", () => {
    expect(
      welcomeTriggerForMetadata({
        stackUserId: "user-1",
        plan: "pro",
        app: "cmux",
      }),
    ).toBe("pro_plan");
  });

  test("founders_edition wins when both shapes are present", () => {
    expect(
      welcomeTriggerForMetadata({
        founders_edition: "true",
        plan: "pro",
        app: "cmux",
      }),
    ).toBe("founders_edition");
  });

  test("cmux Team checkout metadata classifies as team_plan", () => {
    expect(
      welcomeTriggerForMetadata({
        stackTeamId: "team-1",
        plan: "team",
        app: "cmux",
      }),
    ).toBe("team_plan");
  });

  test("everything else classifies as other", () => {
    expect(welcomeTriggerForMetadata({ plan: "pro", app: "other" })).toBe(
      "other",
    );
    expect(welcomeTriggerForMetadata({ plan: "pro" })).toBe("other");
    expect(welcomeTriggerForMetadata({ founders_edition: "false" })).toBe(
      "other",
    );
    expect(welcomeTriggerForMetadata({})).toBe("other");
    expect(welcomeTriggerForMetadata(null)).toBe("other");
    expect(welcomeTriggerForMetadata(undefined)).toBe("other");
  });
});

describe("welcomeTriggerForCheckout", () => {
  test("falls back to expanded subscription metadata when session metadata is empty", () => {
    expect(
      welcomeTriggerForCheckout(
        {},
        { app: "cmux", plan: "pro", stackUserId: "user-1" },
      ),
    ).toBe("pro_plan");
  });

  test("does not let subscription metadata override a foreign session marker", () => {
    expect(
      welcomeTriggerForCheckout(
        { app: "other", plan: "pro" },
        { app: "cmux", plan: "pro" },
      ),
    ).toBe("other");
  });

  test("falls back when the session has only a partial product marker", () => {
    expect(
      welcomeTriggerForCheckout(
        { app: "cmux" },
        { app: "cmux", plan: "pro" },
      ),
    ).toBe("pro_plan");
    expect(
      welcomeTriggerForCheckout(
        { founders_edition: "false" },
        { app: "cmux", plan: "pro" },
      ),
    ).toBe("pro_plan");
  });

  test("keeps malformed Founder metadata from falling back to another product", () => {
    expect(
      welcomeTriggerForCheckout(
        { founders_edition: "true", app: "cmux", plan: "pro" },
        { app: "cmux", plan: "pro" },
      ),
    ).toBe("other");
  });
});

describe("foundersThreadRef", () => {
  test("different sessions produce different thread keys (a new Gmail thread each)", () => {
    expect(foundersThreadRef("cs_test_aaa")).not.toBe(
      foundersThreadRef("cs_test_bbb"),
    );
  });

  test("the same session id produces a stable thread key (idempotent re-send stays in one thread)", () => {
    expect(foundersThreadRef("cs_test_aaa")).toBe(
      foundersThreadRef("cs_test_aaa"),
    );
  });
});

describe("buildFoundersWelcomeEmail", () => {
  test("X-Entity-Ref-ID differs across subscriptions but is stable per session", () => {
    const first = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "c1@example.com",
      sessionRef: "cs_test_aaa",
    });
    const second = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "c2@example.com",
      customerName: "Grace Hopper",
      sessionRef: "cs_test_bbb",
    });
    // A Stripe redelivery of the SAME checkout session (same id) must reuse the
    // same ref so it lands in the existing single thread, not a duplicate.
    const redeliveredFirst = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "c1@example.com",
      sessionRef: "cs_test_aaa",
    });

    expect(first.headers[THREAD_HEADER]).not.toBe(second.headers[THREAD_HEADER]);
    expect(first.headers[THREAD_HEADER]).toBe(
      redeliveredFirst.headers[THREAD_HEADER],
    );
    expect(first.headers[THREAD_HEADER]).toBe(foundersThreadRef("cs_test_aaa"));
  });

  test("subject stays clean and constant for Founder's Edition subscriptions", () => {
    const first = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "c1@example.com",
      sessionRef: "cs_test_aaa",
    });
    const second = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "c2@example.com",
      sessionRef: "cs_test_bbb",
    });
    expect(first.subject).toBe(EMAIL_SUBJECT);
    expect(second.subject).toBe(EMAIL_SUBJECT);
  });

  test("Pro uses the localized personal payload", async () => {
    const founders = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_founder",
    });
    const pro = await buildProWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_pro",
      locale: "en",
    });
    expect(pro.subject).toBe(PRO_EMAIL_SUBJECT);
    expect(pro.from).toBe(founders.from);
    expect(pro.to).toEqual(founders.to);
    expect(pro.cc).toEqual(founders.cc);
    expect(pro.replyTo).toBe(founders.replyTo);
    expect(pro.text).toContain("Thanks for joining cmux Pro!");
    expect(pro.text).toContain("Sign up for TestFlight: https://cmux.com/dashboard/testflight");
    expect(pro.headers[THREAD_HEADER]).toBe("founders-welcome/cs_pro");
  });

  test("loads the selected locale for the Pro subject and body", async () => {
    const pro = await buildProWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_pro_ja",
      locale: "ja",
    });

    expect(pro.subject).toBe("cmux Pro へようこそ！");
    expect(pro.text).toContain("cmux Pro にご参加いただきありがとうございます！");
    expect(pro.text).toContain("TestFlight に登録する：https://cmux.com/dashboard/testflight");
  });

  test("uses the selected locale's fallback name when the customer has no name", async () => {
    const pro = await buildProWelcomeEmail({
      ...baseParams,
      customerName: null,
      to: "customer@example.com",
      sessionRef: "cs_pro_ja_fallback",
      locale: "ja",
    });

    expect(pro.text.startsWith("お客様 さん、こんにちは！")).toBe(true);
    expect(pro.text).not.toContain("there");
  });

  test("falls back to English when a locale catalog is unavailable", async () => {
    const pro = await buildProWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_pro_fallback",
      locale: "missing-locale" as never,
    });

    expect(pro.subject).toBe(PRO_EMAIL_SUBJECT);
    expect(pro.text).toContain("Thanks for joining cmux Pro!");
  });

  test("recipients, sender, and reply-to are preserved unchanged", () => {
    const email = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_test_aaa",
    });
    expect(email.to).toEqual(["customer@example.com"]);
    expect(email.cc).toEqual(FOUNDER_CC);
    expect(email.replyTo).toBe(REPLY_TO);
    expect(email.from).toBe("Austin Wang <austin@manaflow.ai>");
  });

  test("greets by first name and falls back to a friendly default", () => {
    const named = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_test_aaa",
    });
    const anonymous = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      customerName: null,
      sessionRef: "cs_test_aaa",
    });
    expect(named.text.startsWith("Hi Sample!")).toBe(true);
    expect(anonymous.text.startsWith("Hi there!")).toBe(true);
  });

  test("announces the iOS beta and asks for a corrected TestFlight email", () => {
    const email = buildFoundersWelcomeEmail({
      ...baseParams,
      to: "customer@example.com",
      sessionRef: "cs_test_aaa",
    });

    const iosBetaParagraph =
      "cmux iOS Beta is out for cmux Founder's Edition! If you have a different " +
      "TestFlight email, please reply to this email with the new email address. " +
      "Otherwise, we'll send it to the one on file.";

    // The new paragraph must be present verbatim (lowercase "cmux", "cmux
    // Founder's Edition", and one-word "TestFlight" are intentional brand/style).
    expect(email.text).toContain(iosBetaParagraph);

    // It must be its own block — separated by blank lines from the surrounding
    // paragraphs — and sit after the contact details, just above the sign-off.
    const paragraphs = email.text.split("\n\n");
    expect(paragraphs).toContain(iosBetaParagraph);

    const contactIndex = paragraphs.findIndex((p) =>
      p.startsWith("My number is"),
    );
    const iosBetaIndex = paragraphs.indexOf(iosBetaParagraph);
    const signOffIndex = paragraphs.findIndex((p) => p.startsWith("Best,"));

    expect(contactIndex).toBeGreaterThanOrEqual(0);
    expect(signOffIndex).toBeGreaterThanOrEqual(0);
    expect(iosBetaIndex).toBeGreaterThan(contactIndex);
    expect(iosBetaIndex).toBeLessThan(signOffIndex);
  });
});
