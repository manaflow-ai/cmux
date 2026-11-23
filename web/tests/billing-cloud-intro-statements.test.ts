import { describe, expect, mock, test } from "bun:test";

import en from "../messages/en.json";
import {
  CLOUD_PASS_USAGE_UNAVAILABLE,
  buildCloudIntroStatement,
  buildCloudIntroStatementEmail,
  cloudIntroStatementDueAt,
  cloudIntroStatementLinks,
  cloudIntroStatementLog,
  cloudIntroStatementNotice,
  cloudIntroStatementText,
  dueCloudIntroStatement,
  latestCloudIntroStatement,
  type CloudIntroRenewalView,
  type CloudPassUsage,
} from "../services/billing/cloudIntroStatements";
import {
  claimedStatementLog,
  type CloudIntroStatementRow,
  type CloudIntroStatementStore,
} from "../services/billing/cloudIntroStatementStore";
import {
  cloudIntroStatementCopy,
  runCloudIntroStatements,
  type CloudIntroStatementJobDependencies,
} from "../services/billing/cloudIntroStatementJob";
import { cloudPassUsageFromIntervals, createCloudPassUsageReader } from "../services/billing/cloudPassUsage";

const DAY = 24 * 60 * 60 * 1000;
const STARTED = new Date("2026-11-01T09:30:00.000Z");
const ENDS = new Date(STARTED.getTime() + 30 * DAY);
const ON = { CMUX_CLOUD_INTRO: "1" };
const OFF = { NODE_ENV: "production", VERCEL_ENV: "production" };
const READ: CloudPassUsage = { status: "read", chiefAwakeMinutes: null, machineMinutes: 1234, machinesStarted: 3 };

function pass(overrides: Partial<CloudIntroStatementRow> = {}): CloudIntroStatementRow {
  return {
    checkoutSessionId: "cs_pass_1",
    stackUserId: "user_1",
    status: "granted",
    renewOnPlus: false,
    startedAt: STARTED,
    endsAt: ENDS,
    statements: {},
    stripeCustomerId: "cus_1",
    paymentMethodId: null,
    ...overrides,
  };
}

/** Pass day `day` at `offsetMs` after its start. */
function onDay(day: number, offsetMs = 0): Date {
  return new Date(STARTED.getTime() + (day - 1) * DAY + offsetMs);
}

function memoryStore(rows: CloudIntroStatementRow[]) {
  const byId = new Map(rows.map((row) => [row.checkoutSessionId, row]));
  const deliveries: { id: string; day: number; delivery: string }[] = [];
  const store: CloudIntroStatementStore = {
    async listCandidates() {
      return [...byId.values()];
    },
    async claim(id, now, build) {
      // Mirrors the drizzle claim: decide on the current row, write, then return.
      const row = byId.get(id);
      if (!row) return null;
      const due = dueCloudIntroStatement(row, now);
      if (!due) return null;
      const statement = build(row, due);
      if (!statement) return null;
      byId.set(id, { ...row, statements: claimedStatementLog(row.statements, due, statement, now) });
      return { pass: row, day: due.day, statement };
    },
    async markDelivery(id, day, delivery) {
      deliveries.push({ id, day, delivery });
      const row = byId.get(id)!;
      const record = row.statements[`${day}`];
      if (record) byId.set(id, { ...row, statements: { ...row.statements, [`${day}`]: { ...record, delivery } } });
    },
    async latestForUser(stackUserId) {
      return [...byId.values()].find((row) => row.stackUserId === stackUserId) ?? null;
    },
  };
  return { store, rows: byId, deliveries };
}

function harness(
  rows: CloudIntroStatementRow[],
  overrides: Partial<CloudIntroStatementJobDependencies> = {},
) {
  const memory = memoryStore(rows);
  const sendEmail = mock(async (_payload: unknown, _options: { idempotencyKey: string }) => ({ error: null }));
  const readUsage = mock(async () => READ);
  const deps = (now: Date): CloudIntroStatementJobDependencies => ({
    env: ON,
    now,
    store: memory.store,
    readUsage,
    recipientEmail: async () => "buyer@example.com",
    sendEmail,
    fromEmail: "pro@cmux.com",
    replyTo: "pro@cmux.com",
    origin: "https://cmux.com",
    ...overrides,
  });
  return { ...memory, sendEmail, readUsage, deps };
}

describe("which statement is due", () => {
  test("day 21 starts exactly 20 days after the pass started", () => {
    expect(cloudIntroStatementDueAt(STARTED, 21).toISOString()).toBe(onDay(21).toISOString());
    expect(dueCloudIntroStatement(pass(), new Date(onDay(21).getTime() - 1))).toBeNull();
    expect(dueCloudIntroStatement(pass(), onDay(21))).toEqual({ day: 21, superseded: [] });
  });

  test("day 27 and day 30 at their first instant, not a millisecond before", () => {
    const sent21 = pass({ statements: { "21": { at: onDay(21).toISOString(), delivery: "emailed" } } });
    expect(dueCloudIntroStatement(sent21, new Date(onDay(27).getTime() - 1))).toBeNull();
    expect(dueCloudIntroStatement(sent21, onDay(27))).toEqual({ day: 27, superseded: [] });
    const sent27 = pass({
      statements: {
        "21": { at: onDay(21).toISOString(), delivery: "emailed" },
        "27": { at: onDay(27).toISOString(), delivery: "emailed" },
      },
    });
    expect(dueCloudIntroStatement(sent27, new Date(onDay(30).getTime() - 1))).toBeNull();
    expect(dueCloudIntroStatement(sent27, onDay(30))).toEqual({ day: 30, superseded: [] });
  });

  test("a late run sends only the latest due day and supersedes the missed ones", () => {
    expect(dueCloudIntroStatement(pass(), onDay(28))).toEqual({ day: 27, superseded: [21] });
    expect(dueCloudIntroStatement(pass(), onDay(30, 3600_000))).toEqual({ day: 30, superseded: [21, 27] });
  });

  test("a day at or before a recorded one is never due again", () => {
    const sent27 = pass({ statements: { "27": { at: onDay(27).toISOString(), delivery: "email_failed" } } });
    expect(dueCloudIntroStatement(sent27, onDay(29))).toBeNull();
    const sent30 = pass({ statements: { "30": { at: onDay(30).toISOString(), delivery: "emailed" } } });
    expect(dueCloudIntroStatement(sent30, onDay(30, DAY / 2))).toBeNull();
  });

  test("nothing after the late window past the pass end, and nothing for a pass that was not granted", () => {
    expect(dueCloudIntroStatement(pass(), new Date(ENDS.getTime() + DAY - 1))?.day).toBe(30);
    expect(dueCloudIntroStatement(pass(), new Date(ENDS.getTime() + DAY))).toBeNull();
    expect(dueCloudIntroStatement(pass({ status: "refused" }), onDay(21))).toBeNull();
    expect(dueCloudIntroStatement(pass({ status: "open" }), onDay(21))).toBeNull();
    expect(dueCloudIntroStatement(pass({ startedAt: null, endsAt: null }), onDay(21))).toBeNull();
  });

  test("the stored log is read defensively", () => {
    expect(cloudIntroStatementLog(null)).toEqual({});
    expect(cloudIntroStatementLog(["21"])).toEqual({});
    expect(cloudIntroStatementLog({ "21": { at: "x", delivery: "emailed" }, "22": { at: "x" }, "27": 1 }))
      .toEqual({ "21": { at: "x", delivery: "emailed" } });
  });
});

describe("the statement", () => {
  function statement(day: 21 | 27 | 30, usage: CloudPassUsage = READ, renewal: CloudIntroRenewalView = "none") {
    return buildCloudIntroStatement({ pass: pass(), day, usage, now: onDay(day, 60_000), renewal });
  }

  test("used against included, in hours and machine-minutes, with days left", () => {
    const built = statement(21);
    expect(built.machines).toEqual({ includedMinutes: 3000, usedMinutes: 1234, started: 3 });
    expect(built.chief).toEqual({ includedHours: 100, usedHours: null });
    expect(built.daysLeft).toBe(10);
    expect(built.ask).toBe(false);
    const text = cloudIntroStatementText(built, cloudIntroStatementCopy, cloudIntroStatementLinks(""));
    expect(text.lines).toContain("Machines: 1,234 of 3,000 machine-minutes used.");
    expect(text.lines).toContain("Machines started: 3.");
    expect(text.lines).toContain("10 days left. The pass ends on December 1, 2026.");
    expect(text.lines).toContain("You will not be charged.");
    expect(text.choices).toEqual([]);
  });

  test("Chief hours show only when read", () => {
    const built = statement(21, { status: "read", chiefAwakeMinutes: 150, machineMinutes: 10, machinesStarted: 1 });
    expect(built.chief.usedHours).toBe(2.5);
    const text = cloudIntroStatementText(built, cloudIntroStatementCopy, cloudIntroStatementLinks(""));
    expect(text.lines).toContain("Chief: 2.5 of 100 awake hours used.");
  });

  test("unavailable usage shows no number that was not read", () => {
    const built = statement(27, CLOUD_PASS_USAGE_UNAVAILABLE);
    expect(built.machines.usedMinutes).toBeNull();
    expect(built.machines.started).toBeNull();
    expect(built.chief.usedHours).toBeNull();
    const text = cloudIntroStatementText(built, cloudIntroStatementCopy, cloudIntroStatementLinks(""));
    expect(text.lines).toContain(
      "Machines: 3,000 machine-minutes included. Usage could not be read for this statement.",
    );
    expect(text.lines).toContain(
      "Chief: 100 awake hours included. Chief hours are not measured on their own yet.",
    );
    expect(text.lines.some((line) => line.startsWith("Machines started"))).toBe(false);
    expect(text.lines.join(" ")).not.toMatch(/\b0 of\b/);
  });

  test("day 30 asks Plus, Pro, or not now, with what happens after", () => {
    const built = statement(30);
    expect(built.ask).toBe(true);
    expect(built.daysLeft).toBe(1);
    const text = cloudIntroStatementText(built, cloudIntroStatementCopy, cloudIntroStatementLinks("https://cmux.com"));
    expect(text.subject).toBe(en.emails.cloudPassStatement.subjectLastDay);
    expect(text.choices.map((choice) => choice.key)).toEqual(["plus", "pro", "not_now"]);
    expect(text.choices[0]!.href).toBe(
      "https://cmux.com/api/billing/checkout?plan=go&interval=month&cmux_source=cloud_pass&returnTo=%2Fdashboard%2Fbilling",
    );
    expect(text.choices[1]!.href).toContain("plan=pro&interval=month");
    expect(text.choices[2]!.href).toBe("https://cmux.com/dashboard/billing?pass=not-now");
    expect(text.after).toContain("kept for 14 days");
    expect(text.after).toContain("before anything is deleted");
  });

  test("a renew buyer's statement says the choice is saved and we ask first", () => {
    const text = cloudIntroStatementText(statement(27, READ, "saved_ask_first"), cloudIntroStatementCopy, cloudIntroStatementLinks(""));
    expect(text.lines).toContain(en.emails.cloudPassStatement.renewSaved);
    expect(text.lines).not.toContain(en.emails.cloudPassStatement.notCharged);
    expect(text.turnOff).toBeNull();
  });

  test("the email carries text and escaped HTML, one reference per pass day", () => {
    const email = buildCloudIntroStatementEmail({
      from: "pro@cmux.com",
      to: "buyer@example.com",
      replyTo: "pro@cmux.com",
      checkoutSessionId: "cs_pass_1",
      statement: statement(30),
      copy: cloudIntroStatementCopy,
      links: cloudIntroStatementLinks("https://cmux.com"),
    });
    expect(email.to).toEqual(["buyer@example.com"]);
    expect(email.headers["X-Entity-Ref-ID"]).toBe("cloud-pass-statement/cs_pass_1/30");
    expect(email.text).toContain("Not now: https://cmux.com/dashboard/billing?pass=not-now");
    expect(email.html).toContain('href="https://cmux.com/api/billing/checkout?plan=go&amp;interval=month');
    expect(email.html).not.toMatch(/<script/i);
  });

  test("the dashboard notice uses relative links and lasts the kept days after the pass", () => {
    const built = statement(30);
    const notice = cloudIntroStatementNotice(built, cloudIntroStatementCopy);
    expect(notice.day).toBe(30);
    expect(notice.choices.every((choice) => choice.href.startsWith("/"))).toBe(true);
    const stored = pass({ statements: { "30": { at: onDay(30).toISOString(), delivery: "emailed", statement: built } } });
    expect(latestCloudIntroStatement(stored, onDay(30))).toEqual(built);
    expect(latestCloudIntroStatement(stored, new Date(ENDS.getTime() + 14 * DAY - 1))).toEqual(built);
    expect(latestCloudIntroStatement(stored, new Date(ENDS.getTime() + 14 * DAY))).toBeNull();
    expect(latestCloudIntroStatement(pass(), onDay(22))).toBeNull();
  });
});

describe("statement copy", () => {
  // Public repository: copy names no vendor other than Claude and Codex, no cost to us, no margin.
  const FORBIDDEN = /\b(cost|costs|margin|margins|markup|wholesale|profit|aws|amazon|gcp|google cloud|azure|freestyle|e2b|daytona|modal|morph|fly\.io|vercel|planetscale|stripe|resend|openai|anthropic|gemini|cloudflare|hetzner)\b/i;

  test("names no vendor, cost or margin", () => {
    const strings = [
      ...Object.values(en.emails.cloudPassStatement),
      ...Object.values(en.dashboard.billing.passStatement),
    ];
    for (const value of strings) expect(value).not.toMatch(FORBIDDEN);
    for (const day of [21, 27, 30] as const) {
      for (const renewal of ["none", "saved_ask_first"] as const) {
        const built = buildCloudIntroStatement({ pass: pass(), day, usage: READ, now: onDay(day), renewal });
        const email = buildCloudIntroStatementEmail({
          from: "pro@cmux.com",
          to: "buyer@example.com",
          replyTo: "pro@cmux.com",
          checkoutSessionId: "cs_pass_1",
          statement: built,
          copy: cloudIntroStatementCopy,
          links: cloudIntroStatementLinks("https://cmux.com"),
        });
        expect(`${email.subject}\n${email.text}`).not.toMatch(FORBIDDEN);
      }
    }
  });
});

describe("the statement cron step", () => {
  test("flag off: nothing is read, claimed or sent", async () => {
    const h = harness([pass()], { env: OFF });
    const result = await runCloudIntroStatements(h.deps(onDay(21)));
    expect(result).toEqual({ skipped: true, considered: 0, sent: 0, noEmail: 0, failed: 0 });
    expect(h.readUsage).not.toHaveBeenCalled();
    expect(h.sendEmail).not.toHaveBeenCalled();
    expect(h.rows.get("cs_pass_1")!.statements).toEqual({});
  });

  test("sends a due statement to the buyer once, however often the cron runs", async () => {
    const h = harness([pass()]);
    const first = await runCloudIntroStatements(h.deps(onDay(21)));
    expect(first.sent).toBe(1);
    await runCloudIntroStatements(h.deps(onDay(21, 60_000)));
    await runCloudIntroStatements(h.deps(onDay(26)));
    expect(h.sendEmail).toHaveBeenCalledTimes(1);
    const [payload, options] = h.sendEmail.mock.calls[0]! as [{ to: string[] }, { idempotencyKey: string }];
    expect(payload.to).toEqual(["buyer@example.com"]);
    expect(options.idempotencyKey).toBe("cmux-cloud-pass-statement/cs_pass_1/21");
    expect(h.rows.get("cs_pass_1")!.statements["21"]?.delivery).toBe("emailed");
    expect(h.readUsage).toHaveBeenCalledWith({ stackUserId: "user_1", from: STARTED, to: onDay(21) });
  });

  test("two runs at once send one email", async () => {
    const h = harness([pass()]);
    await Promise.all([runCloudIntroStatements(h.deps(onDay(21))), runCloudIntroStatements(h.deps(onDay(21)))]);
    expect(h.sendEmail).toHaveBeenCalledTimes(1);
  });

  test("days 21, 27 and 30 each go out once, in order", async () => {
    const h = harness([pass()]);
    for (const day of [21, 22, 27, 28, 30, 31]) await runCloudIntroStatements(h.deps(onDay(day, 1000)));
    expect(h.sendEmail.mock.calls.map(([, options]) => options.idempotencyKey)).toEqual([
      "cmux-cloud-pass-statement/cs_pass_1/21",
      "cmux-cloud-pass-statement/cs_pass_1/27",
      "cmux-cloud-pass-statement/cs_pass_1/30",
    ]);
  });

  test("a failed email is recorded and not retried", async () => {
    const h = harness([pass()]);
    h.sendEmail.mockImplementation((async () => ({ error: new Error("rejected") })) as never);
    const result = await runCloudIntroStatements(h.deps(onDay(21)));
    expect(result.failed).toBe(1);
    await runCloudIntroStatements(h.deps(onDay(21, 3600_000)));
    expect(h.sendEmail).toHaveBeenCalledTimes(1);
    expect(h.rows.get("cs_pass_1")!.statements["21"]?.delivery).toBe("email_failed");
  });

  test("a buyer without an email address gets the notice, no email", async () => {
    const h = harness([pass()], { recipientEmail: async () => null });
    const result = await runCloudIntroStatements(h.deps(onDay(21)));
    expect(result.noEmail).toBe(1);
    expect(h.sendEmail).not.toHaveBeenCalled();
    expect(h.rows.get("cs_pass_1")!.statements["21"]?.delivery).toBe("no_email");
    expect(h.rows.get("cs_pass_1")!.statements["21"]?.statement?.day).toBe(21);
  });

  test("unavailable usage still sends the statement, without numbers", async () => {
    const h = harness([pass()], { readUsage: async () => CLOUD_PASS_USAGE_UNAVAILABLE });
    await runCloudIntroStatements(h.deps(onDay(27)));
    const [payload] = h.sendEmail.mock.calls[0]! as unknown as [{ text: string }];
    expect(payload.text).toContain("Usage could not be read for this statement.");
    expect(payload.text).not.toMatch(/\d+ of 3,000/);
    expect(h.rows.get("cs_pass_1")!.statements["21"]?.delivery).toBe("superseded");
  });

  test("a renew buyer is told the choice is saved, with the charge off", async () => {
    const h = harness([pass({ renewOnPlus: true, paymentMethodId: "pm_1" })]);
    await runCloudIntroStatements(h.deps(onDay(27)));
    const [payload] = h.sendEmail.mock.calls[0]! as unknown as [{ text: string }];
    expect(payload.text).toContain(en.emails.cloudPassStatement.renewSaved);
  });

  test("one pass failing does not stop the others", async () => {
    const h = harness([pass(), pass({ checkoutSessionId: "cs_pass_2", stackUserId: "user_2" })], {
      readUsage: async ({ stackUserId }) => {
        if (stackUserId === "user_1") throw new Error("boom");
        return READ;
      },
    });
    const result = await runCloudIntroStatements(h.deps(onDay(21)));
    expect(result).toMatchObject({ considered: 2, sent: 1, failed: 1 });
  });
});

describe("the usage read", () => {
  const from = STARTED;
  const to = onDay(21);
  const shape = (vcpus: number) => ({
    cmuxResourceReservation: { vcpus, memoryMb: vcpus * 4096, diskMb: 10240 },
  });

  test("vCPU-weighted machine-minutes inside the window, machines started in it", async () => {
    const reader = createCloudPassUsageReader(async () => [
      // 30 minutes on 2 vCPUs.
      { vmId: "vm_a", startedAt: new Date(from.getTime() + DAY), endedAt: new Date(from.getTime() + DAY + 30 * 60_000), metadata: shape(2) },
      // Started before the pass: only the 10 minutes inside count, and it is not "started".
      { vmId: "vm_b", startedAt: new Date(from.getTime() - 60 * 60_000), endedAt: new Date(from.getTime() + 10 * 60_000), metadata: shape(4) },
      // Still running at `to`: 5 minutes on 1 vCPU.
      { vmId: "vm_c", startedAt: new Date(to.getTime() - 5 * 60_000), endedAt: null, metadata: shape(1) },
    ]);
    const usage = await reader({ stackUserId: "user_1", from, to });
    if (usage.status !== "read") throw new Error("expected a read");
    expect(usage.machinesStarted).toBe(2);
    expect(usage.chiefAwakeMinutes).toBeNull();
    expect(usage.machineMinutes).toBe(30 * 2 + 10 * 4 + 5 * 1);
  });

  test("a machine without a recorded shape makes machine-minutes unread, not guessed", () => {
    const usage = cloudPassUsageFromIntervals(
      [{ vmId: "vm_a", startedAt: new Date(from.getTime() + DAY), endedAt: new Date(from.getTime() + DAY + 60_000), metadata: {} }],
      from,
      to,
    );
    expect(usage).toEqual({ status: "read", chiefAwakeMinutes: null, machineMinutes: null, machinesStarted: 1 });
  });

  test("a failed read is unavailable", async () => {
    const reader = createCloudPassUsageReader(async () => {
      throw new Error("DATABASE_URL is required");
    });
    expect(await reader({ stackUserId: "user_1", from, to })).toEqual(CLOUD_PASS_USAGE_UNAVAILABLE);
  });
});

describe("the statement cron route", () => {
  const captureCoderouterError = mock(() => {});
  mock.module("../services/errors", () => ({ captureBillingError: () => {}, captureCoderouterError }));

  test("refuses without the cron secret and does nothing with the flag off", async () => {
    const { GET } = await import("../app/api/cron/cloud-pass-statements/route");
    const original = process.env.CRON_SECRET;
    try {
      delete process.env.CRON_SECRET;
      expect((await GET(new Request("https://cmux.test/api/cron/cloud-pass-statements"))).status).toBe(401);
      process.env.CRON_SECRET = "expected";
      const response = await GET(new Request("https://cmux.test/api/cron/cloud-pass-statements", {
        headers: { authorization: "Bearer expected" },
      }));
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ ok: true, skipped: true, sent: 0 });
    } finally {
      if (original === undefined) delete process.env.CRON_SECRET;
      else process.env.CRON_SECRET = original;
    }
  });
});
