// Argument parsing and safety gates for the newsletter CLI scripts, kept
// separate from the scripts themselves so the gates are directly
// unit-testable (web/tests/newsletter-cli.test.ts).
//
// Safety posture:
//   - sync is a dry run unless --apply is passed.
//   - email:test refuses any recipient other than the hardcoded default
//     unless an explicit, deliberately-verbose override flag accompanies it.
//   - email:draft has no send capability at all; unknown flags (for example
//     a hopeful --send) are hard errors. Broadcast sending is a human click
//     in the Resend dashboard, by design.

export const AUDIENCE_CHOICES = ["users", "founders", "all"] as const;
export type AudienceChoice = (typeof AUDIENCE_CHOICES)[number];

export const TEMPLATE_CHOICES = ["product-update"] as const;
export type TemplateChoice = (typeof TEMPLATE_CHOICES)[number];

export const DEFAULT_TEST_RECIPIENT = "austin@manaflow.ai";
export const TEST_RECIPIENT_OVERRIDE_FLAG =
  "--dangerously-email-someone-other-than-austin";

export type SyncArgs = {
  apply: boolean;
  audience: AudienceChoice;
  json: boolean;
};

export function parseSyncArgs(argv: string[]): SyncArgs {
  const args: SyncArgs = { apply: false, audience: "all", json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--apply") {
      args.apply = true;
    } else if (arg === "--json") {
      args.json = true;
    } else if (arg === "--audience") {
      const value = argv[++i];
      if (!AUDIENCE_CHOICES.includes(value as AudienceChoice)) {
        throw new Error(
          `--audience must be one of: ${AUDIENCE_CHOICES.join(", ")}`,
        );
      }
      args.audience = value as AudienceChoice;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

export type DraftArgs = {
  template: TemplateChoice;
  audience: Exclude<AudienceChoice, "all">;
  subject?: string;
};

export function parseDraftArgs(argv: string[]): DraftArgs {
  let template: TemplateChoice | null = null;
  let audience: Exclude<AudienceChoice, "all"> | null = null;
  let subject: string | undefined;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--template") {
      const value = argv[++i];
      if (!TEMPLATE_CHOICES.includes(value as TemplateChoice)) {
        throw new Error(
          `--template must be one of: ${TEMPLATE_CHOICES.join(", ")}`,
        );
      }
      template = value as TemplateChoice;
    } else if (arg === "--audience") {
      const value = argv[++i];
      if (value !== "users" && value !== "founders") {
        throw new Error('--audience must be "users" or "founders"');
      }
      audience = value;
    } else if (arg === "--subject") {
      const value = argv[++i];
      if (!value) {
        throw new Error("--subject requires a value");
      }
      subject = value;
    } else {
      // No pass-through: anything unrecognized (including any send-shaped
      // flag) aborts before a single API call is made.
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!template) {
    throw new Error("--template is required");
  }
  if (!audience) {
    throw new Error('--audience is required ("users" or "founders")');
  }
  return { template, audience, ...(subject ? { subject } : {}) };
}

export type TestSendArgs = {
  template: TemplateChoice;
  to: string;
  greetingName?: string;
};

export function parseTestSendArgs(argv: string[]): TestSendArgs {
  let template: TemplateChoice | null = null;
  let to = DEFAULT_TEST_RECIPIENT;
  let overrideAcknowledged = false;
  let greetingName: string | undefined;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--template") {
      const value = argv[++i];
      if (!TEMPLATE_CHOICES.includes(value as TemplateChoice)) {
        throw new Error(
          `--template must be one of: ${TEMPLATE_CHOICES.join(", ")}`,
        );
      }
      template = value as TemplateChoice;
    } else if (arg === "--to") {
      const value = argv[++i];
      if (!value) {
        throw new Error("--to requires a value");
      }
      to = value.trim();
    } else if (arg === TEST_RECIPIENT_OVERRIDE_FLAG) {
      overrideAcknowledged = true;
    } else if (arg === "--greeting-name") {
      const value = argv[++i];
      if (!value) {
        throw new Error("--greeting-name requires a value");
      }
      greetingName = value;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!template) {
    throw new Error("--template is required");
  }
  if (
    to.toLowerCase() !== DEFAULT_TEST_RECIPIENT &&
    !overrideAcknowledged
  ) {
    throw new Error(
      `Refusing to send a test email to ${to}. The only default-allowed ` +
        `recipient is ${DEFAULT_TEST_RECIPIENT}; pass ` +
        `${TEST_RECIPIENT_OVERRIDE_FLAG} if you really mean it.`,
    );
  }
  return { template, to, ...(greetingName ? { greetingName } : {}) };
}
