import { describe, expect, test } from "bun:test";

// Safety gates on the newsletter CLI surface: sync defaults to dry run,
// email:test refuses non-default recipients without the explicit override
// flag, and email:draft accepts no send-shaped arguments at all.

import {
  DEFAULT_TEST_RECIPIENT,
  TEST_RECIPIENT_OVERRIDE_FLAG,
  parseDraftArgs,
  requirePrivacyDisclosureConfirmation,
  parseSyncArgs,
  parseTestSendArgs,
} from "../services/newsletter/cli";

describe("parseSyncArgs", () => {
  test("defaults to a dry run over all audiences", () => {
    expect(parseSyncArgs([])).toEqual({
      apply: false,
      audience: "all",
      json: false,
    });
  });

  test("--apply is the only way to enable writes", () => {
    expect(parseSyncArgs(["--apply"]).apply).toBe(true);
    expect(parseSyncArgs(["--audience", "users"]).apply).toBe(false);
  });

  test("rejects unknown arguments instead of ignoring them", () => {
    expect(() => parseSyncArgs(["--aply"])).toThrow(/Unknown argument/);
    expect(() => parseSyncArgs(["--audience", "everyone"])).toThrow(
      /--audience must be/,
    );
  });

  test("requires an explicit privacy acknowledgement before users apply", () => {
    expect(() =>
      requirePrivacyDisclosureConfirmation({
        apply: true,
        audience: "users",
        json: false,
      }),
    ).toThrow(/confirm-privacy-disclosure/);
    expect(() =>
      requirePrivacyDisclosureConfirmation({
        apply: true,
        audience: "all",
        json: false,
        confirmPrivacyDisclosure: true,
      }),
    ).not.toThrow();
    expect(() =>
      requirePrivacyDisclosureConfirmation({
        apply: true,
        audience: "founders",
        json: false,
      }),
    ).not.toThrow();
  });
});

describe("parseDraftArgs", () => {
  test("requires template and a single concrete audience", () => {
    expect(
      parseDraftArgs(["--template", "product-update", "--audience", "users"]),
    ).toEqual({ template: "product-update", audience: "users" });
    expect(() => parseDraftArgs(["--template", "product-update"])).toThrow(
      /--audience is required/,
    );
    expect(() =>
      parseDraftArgs(["--template", "product-update", "--audience", "all"]),
    ).toThrow(/--audience must be/);
    expect(() =>
      parseDraftArgs([
        "--template",
        "founders-feedback-call",
        "--audience",
        "users",
      ]),
    ).toThrow(/may only target the founders audience/);
  });

  test("has no send flag: anything send-shaped is a hard error", () => {
    expect(() =>
      parseDraftArgs([
        "--template",
        "product-update",
        "--audience",
        "users",
        "--send",
      ]),
    ).toThrow(/Unknown argument: --send/);
    expect(() =>
      parseDraftArgs([
        "--template",
        "product-update",
        "--audience",
        "users",
        "--yes-really-send",
      ]),
    ).toThrow(/Unknown argument/);
  });
});

describe("parseTestSendArgs", () => {
  test("defaults the recipient to austin@manaflow.ai", () => {
    expect(parseTestSendArgs(["--template", "product-update"])).toEqual({
      template: "product-update",
      to: DEFAULT_TEST_RECIPIENT,
    });
  });

  test("allows the default recipient to be spelled out explicitly", () => {
    expect(
      parseTestSendArgs([
        "--template",
        "product-update",
        "--to",
        "Austin@Manaflow.ai",
      ]).to.toLowerCase(),
    ).toBe(DEFAULT_TEST_RECIPIENT);
  });

  test("refuses any other recipient without the explicit override flag", () => {
    expect(() =>
      parseTestSendArgs([
        "--template",
        "product-update",
        "--to",
        "someone@example.com",
      ]),
    ).toThrow(/Refusing to send/);
  });

  test("the override flag unlocks exactly the named recipient", () => {
    expect(
      parseTestSendArgs([
        "--template",
        "product-update",
        "--to",
        "someone@example.com",
        TEST_RECIPIENT_OVERRIDE_FLAG,
      ]).to,
    ).toBe("someone@example.com");
  });

  test("free-text values may begin with a single hyphen", () => {
    expect(
      parseDraftArgs([
        "--template",
        "product-update",
        "--audience",
        "users",
        "--subject",
        "-50% off cmux Founder's Edition",
      ]).subject,
    ).toBe("-50% off cmux Founder's Edition");
  });

  test("a value-taking flag never swallows a following flag", () => {
    // Without this guard, --to would consume the override flag as its
    // value and the argument stream would shift silently.
    expect(() =>
      parseTestSendArgs([
        "--template",
        "product-update",
        "--to",
        TEST_RECIPIENT_OVERRIDE_FLAG,
      ]),
    ).toThrow(/--to requires a value/);
    expect(() =>
      parseTestSendArgs(["--template", "product-update", "--to"]),
    ).toThrow(/--to requires a value/);
    expect(() =>
      parseDraftArgs([
        "--template",
        "product-update",
        "--audience",
        "users",
        "--subject",
        "--send",
      ]),
    ).toThrow(/--subject requires a value/);
  });
});
