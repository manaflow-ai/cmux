import { describe, expect, test } from "bun:test";
import {
  buildAccountHealthEmail,
  noticeSection,
  runAccountHealthNotifications,
  selectAccountHealthNotices,
  type AccountHealthDependencies,
  type AccountHealthEmail,
  type BrokenAccountNotice,
} from "../services/coderouter/accountHealthEmail";

const T0 = new Date("2026-09-02T12:00:00.000Z");

function notice(overrides: Partial<BrokenAccountNotice> = {}): BrokenAccountNotice {
  return {
    source: "claude",
    accountId: "11111111-2222-4333-8444-555555555555",
    teamId: "team-1",
    kind: "claude",
    label: "work",
    identifier: "sk-ant-oat01-...HIJ",
    failureCode: "invalid_credential",
    brokenAt: T0,
    createdBy: "user-1",
    ...overrides,
  };
}

function harness(input: {
  claude?: BrokenAccountNotice[];
  subscriptions?: BrokenAccountNotice[];
  recipients?: (notice: BrokenAccountNotice) => readonly { email: string; name: string | null }[];
  failSendTo?: string;
  onRecipients?: () => void;
}) {
  const sent: AccountHealthEmail[] = [];
  const notified: { ids: string[]; at: Date }[] = [];
  const dependencies: AccountHealthDependencies = {
    brokenClaudeAccounts: async () => input.claude ?? [],
    brokenSubscriptionAccounts: async () => input.subscriptions ?? [],
    markNotified: async (notices, at) => {
      notified.push({ ids: notices.map((n) => n.accountId), at });
    },
    recipients: async (n) => {
      input.onRecipients?.();
      return input.recipients?.(n) ?? [{ email: "owner@example.com", name: "Lawrence Chen" }];
    },
    teamName: async () => "manaflow",
    send: async (email) => {
      if (input.failSendTo && email.to === input.failSendTo) throw new Error("resend down");
      sent.push(email);
    },
    fromEmail: () => "coderouter@cmux.com",
    now: () => T0,
  };
  return { dependencies, sent, notified };
}

describe("account health email copy", () => {
  test("says what broke, why, and exactly how to fix it, once", async () => {
    const email = await buildAccountHealthEmail({
      from: "coderouter@cmux.com",
      recipient: { email: "owner@example.com", name: "Lawrence Chen" },
      notices: [
        notice(),
        notice({ source: "subscription", accountId: "66666666-7777-4888-9999-000000000000", kind: "codex", label: "a@x.dev", identifier: "", failureCode: "invalid_grant", createdBy: null }),
      ],
      teamNames: new Map([["team-1", "manaflow"]]),
    });
    expect(email.subject).toBe("Action needed: 2 coderouter accounts stopped working in manaflow");
    expect(email.from).toBe("cmux coderouter <coderouter@cmux.com>");
    expect(email.to).toBe("owner@example.com");
    expect(email.replyTo).toBe("support@cmux.com");
    expect(email.idempotencyKey).toMatch(/^coderouter-account-health-[a-f0-9]{64}$/);
    expect(email.text).toContain("Hi Lawrence,");
    // What and why, per account.
    expect(email.text).toContain("Claude Code token sk-ant-oat01-...HIJ (work) in manaflow, id 11111111");
    expect(email.text).toContain("Anthropic rejected this token three times in a row (invalid_credential) on 2026-09-02 12:00 UTC");
    expect(email.text).toContain("ChatGPT Codex subscription a@x.dev in manaflow, id 66666666");
    expect(email.text).toContain("could not be renewed (invalid_grant)");
    // Exact commands.
    expect(email.text).toContain("cmux coderouter accounts add claude");
    expect(email.text).not.toContain("claude setup-token &&");
    expect(email.text).toContain("cmux coderouter accounts add codex");
    expect(email.text).toContain("cmux coderouter accounts remove 11111111");
    expect(email.text).toContain("https://cmux.com/dashboard/coderouter?team=team-1");
    // The no-spam promise.
    expect(email.text).toContain("exactly one email per account");
    expect(email.html).toContain("<code>cmux coderouter accounts add claude");
    expect(email.html).not.toContain("sk-ant-oat01-abc");
  });

  test("names the fix for every kind", () => {
    expect(noticeSection(notice({ kind: "anthropic-key", identifier: "sk-ant-...wxyz" }), null).fix[0]).toBe("cmux coderouter accounts add anthropic-key --label work");
    expect(noticeSection(notice({ kind: "bedrock", identifier: "AKIA...MNOP", label: "" }), null).fix[0]).toContain("accounts add bedrock --region <region>");
    expect(noticeSection(notice({ kind: "opencode", source: "subscription", identifier: "" }), "team").headline).toContain("OpenCode Go subscription work in team");
    expect(noticeSection(notice({ label: "with space" }), null).fix[0]).toBe("cmux coderouter accounts add claude --label 'with space'");
  });

  test("uses a singular subject for one account and counts teams when several are involved", async () => {
    const one = await buildAccountHealthEmail({ from: "f@cmux.com", recipient: { email: "a@b.c", name: null }, notices: [notice()], teamNames: new Map() });
    expect(one.subject).toBe("Action needed: a coderouter account stopped working in your team");
    expect(one.text).toContain("Hi,");
    const two = await buildAccountHealthEmail({
      from: "f@cmux.com",
      recipient: { email: "a@b.c", name: null },
      notices: [notice(), notice({ teamId: "team-2", accountId: "22222222-2222-4222-8222-222222222222" })],
      teamNames: new Map(),
    });
    expect(two.subject).toBe("Action needed: 2 coderouter accounts stopped working in 2 of your teams");
    expect(two.text).toContain("team=team-1");
    expect(two.text).toContain("team=team-2");
  });

  test("uses the recipient locale when Stack provides one", async () => {
    const email = await buildAccountHealthEmail({
      from: "f@cmux.com",
      recipient: { email: "a@b.c", name: "Lawrence Chen", locale: "ja" },
      notices: [notice()],
      teamNames: new Map([["team-1", "manaflow"]]),
    });
    expect(email.subject).toContain("対応が必要です");
    expect(email.text).toContain("動作しなくなったアカウント");
  });
});

describe("account health notification run", () => {
  test("batches every broken account of a recipient into one email and marks each account once", async () => {
    const second = notice({ accountId: "22222222-2222-4222-8222-222222222222", kind: "anthropic-key", identifier: "sk-ant-...wxyz", label: "" });
    const sub = notice({ source: "subscription", accountId: "33333333-3333-4333-8333-333333333333", kind: "codex", identifier: "", label: "a@x.dev", createdBy: null });
    const { dependencies, sent, notified } = harness({ claude: [notice(), second], subscriptions: [sub] });
    const result = await runAccountHealthNotifications(dependencies);
    expect(result).toEqual({ accounts: 3, emails: 1, recipients: 1, withoutRecipient: 0, failures: 0 });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.subject).toContain("3 coderouter accounts");
    expect(notified).toEqual([{ ids: [notice().accountId, second.accountId, sub.accountId], at: T0 }]);
    // A second run sees nothing new: the store no longer returns them.
    const again = await runAccountHealthNotifications({ ...dependencies, brokenClaudeAccounts: async () => [], brokenSubscriptionAccounts: async () => [] });
    expect(again.emails).toBe(0);
  });

  test("sends to each team member when no creator is known, without duplicating emails", async () => {
    const sub = notice({ source: "subscription", kind: "codex", identifier: "", createdBy: null });
    const { dependencies, sent } = harness({
      subscriptions: [sub],
      recipients: () => [{ email: "a@x.dev", name: "A" }, { email: "b@x.dev", name: null }, { email: "A@X.dev", name: "A again" }],
    });
    const result = await runAccountHealthNotifications(dependencies);
    expect(result.emails).toBe(2);
    expect(sent.map((email) => email.to).sort()).toEqual(["a@x.dev", "b@x.dev"]);
  });

  test("keeps a subscription in the run when Claude has a full batch", () => {
    const claude = Array.from({ length: 200 }, (_, index) => notice({ accountId: `claude-${index}` }));
    const subscription = notice({ source: "subscription", kind: "codex", createdBy: null, accountId: "subscription-1" });
    const selected = selectAccountHealthNotices(claude, [subscription], 200);
    expect(selected).toHaveLength(200);
    expect(selected.some((item) => item.source === "subscription")).toBe(true);
    expect(selected.filter((item) => item.source === "subscription")).toHaveLength(1);
  });

  test("caches team recipient lookup for several subscription notices", async () => {
    let lookups = 0;
    const first = notice({ source: "subscription", kind: "codex", createdBy: null });
    const second = notice({ source: "subscription", kind: "opencode", createdBy: null, accountId: "22222222-2222-4222-8222-222222222222" });
    const { dependencies, sent } = harness({
      subscriptions: [first, second],
      onRecipients: () => { lookups += 1; },
    });
    await runAccountHealthNotifications(dependencies);
    expect(lookups).toBe(1);
    expect(sent).toHaveLength(1);
  });

  test("uses a different idempotency key when the account batch changes", async () => {
    const one = await buildAccountHealthEmail({
      from: "f@cmux.com",
      recipient: { email: "owner@example.com", name: null },
      notices: [notice()],
      teamNames: new Map(),
    });
    const two = await buildAccountHealthEmail({
      from: "f@cmux.com",
      recipient: { email: "owner@example.com", name: null },
      notices: [notice(), notice({ accountId: "22222222-2222-4222-8222-222222222222" })],
      teamNames: new Map(),
    });
    expect(two.idempotencyKey).not.toBe(one.idempotencyKey);
  });

  test("a failed send leaves the account unmarked so the next run retries it", async () => {
    const a = notice();
    const b = notice({ accountId: "22222222-2222-4222-8222-222222222222", teamId: "team-2" });
    const { dependencies, sent, notified } = harness({
      claude: [a, b],
      recipients: (n) => [{ email: n.teamId === "team-1" ? "ok@example.com" : "down@example.com", name: null }],
      failSendTo: "down@example.com",
    });
    const result = await runAccountHealthNotifications(dependencies);
    expect(result).toMatchObject({ emails: 1, failures: 1 });
    expect(sent.map((email) => email.to)).toEqual(["ok@example.com"]);
    expect(notified).toEqual([{ ids: [a.accountId], at: T0 }]);
  });

  test("keeps a team account pending when one member delivery fails", async () => {
    const sub = notice({ source: "subscription", kind: "codex", createdBy: null });
    const { dependencies, sent, notified } = harness({
      subscriptions: [sub],
      recipients: () => [{ email: "ok@example.com", name: null }, { email: "down@example.com", name: null }],
      failSendTo: "down@example.com",
    });
    const result = await runAccountHealthNotifications(dependencies);
    expect(result).toMatchObject({ accounts: 1, emails: 1, recipients: 2, failures: 1 });
    expect(sent.map((email) => email.to)).toEqual(["ok@example.com"]);
    expect(notified).toEqual([]);
  });

  test("accounts with nobody to tell are marked so they are not re-queried forever", async () => {
    const { dependencies, sent, notified } = harness({ claude: [notice({ createdBy: null })], recipients: () => [] });
    const result = await runAccountHealthNotifications(dependencies);
    expect(result).toMatchObject({ accounts: 1, emails: 0, withoutRecipient: 1 });
    expect(sent).toEqual([]);
    expect(notified[0]!.ids).toEqual([notice().accountId]);
  });

  test("does nothing when nothing is broken", async () => {
    const { dependencies, sent, notified } = harness({});
    expect(await runAccountHealthNotifications(dependencies)).toEqual({ accounts: 0, emails: 0, recipients: 0, withoutRecipient: 0, failures: 0 });
    expect(sent).toEqual([]);
    expect(notified).toEqual([]);
  });
});
