import { describe, expect, test } from "bun:test";

import {
  EMAIL_SUBJECT,
  FOUNDER_CC,
  REPLY_TO,
  buildFoundersWelcomeEmail,
  foundersThreadRef,
} from "../app/api/stripe/founders-welcome/welcome-email";

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
  customerName: "Ada Lovelace",
} as const;

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

  test("subject stays clean and constant across subscriptions (threading is header-only)", () => {
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
    expect(named.text.startsWith("Hi Ada!")).toBe(true);
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
