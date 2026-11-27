import { describe, expect, test } from "vitest";
import "./testCatalog";
import { awakeDuration, parseSlackAwake, SlackAwakeController, spentToday, type SlackAwake } from "./slackAwake";

const awake: SlackAwake = {
  allowance_seconds: 7200,
  default_seconds: 7200,
  max_seconds: 86400,
  days: 7,
  senders: [
    { slack_team: "T1", slack_user: "U1", sender_is_owner: true, day: "2026-11-26", seconds: 600, turns: 2 },
    { slack_team: "T1", slack_user: "U2", sender_is_owner: false, day: "2026-11-26", seconds: 9000, turns: 5 },
    { slack_team: "T1", slack_user: "U3", sender_is_owner: false, day: "2026-11-26", seconds: 1800, turns: 1 },
    { slack_team: "T1", slack_user: "U3", sender_is_owner: false, day: "2026-11-25", seconds: 7200, turns: 4 },
  ],
};

describe("spentToday", () => {
  test("reads only today, most time first, owner never capped", () => {
    const rows = spentToday(awake, "2026-11-26", { U2: "Austin" });
    expect(rows.map((r) => [r.name, r.seconds, r.used])).toEqual([
      ["Austin", 9000, 1],
      ["U3", 1800, 0.25],
      ["U1", 600, null],
    ]);
  });
  test("a zero allowance marks every non-owner out", () => {
    const rows = spentToday({ ...awake, allowance_seconds: 0 }, "2026-11-26");
    expect(rows.find((r) => r.user === "U3")?.used).toBe(1);
  });
  test("no rows on a quiet day", () => {
    expect(spentToday(awake, "2026-11-20")).toEqual([]);
  });
});

describe("awakeDuration", () => {
  test.each([
    [0, "0 min"],
    [30, "under 1 min"],
    [2700, "45 min"],
    [7200, "2 h"],
    [4800, "1 h 20 min"],
  ])("%i s -> %s", (s, text) => expect(awakeDuration(s)).toBe(text));
});

describe("parseSlackAwake", () => {
  test("accepts the API value and rejects a bent one", () => {
    expect(parseSlackAwake(awake)).toEqual(awake);
    expect(parseSlackAwake({ ...awake, allowance_seconds: -1 })).toBeNull();
    expect(parseSlackAwake({ ...awake, senders: [{ ...awake.senders[0], day: "today" }] })).toBeNull();
    expect(parseSlackAwake(null)).toBeNull();
    expect(parseSlackAwake({ ...awake, names: { U2: "Austin" } })?.names).toEqual({ U2: "Austin" });
    expect(parseSlackAwake({ ...awake, names: { U2: 7 } })).toBeNull();
  });
});

describe("SlackAwakeController", () => {
  const client = (reply: (params: Record<string, unknown>) => unknown) => {
    const calls: Array<[string, unknown]> = [];
    return {
      calls,
      call: async <R>(op: string, params: unknown): Promise<R> => {
        calls.push([op, params]);
        return reply(params as Record<string, unknown>) as R;
      },
    };
  };

  test("reads with no allowance, then sets seconds", async () => {
    const c = client((params) => ({ ...awake, allowance_seconds: (params.allowance_seconds as number) ?? 7200 }));
    const controller = new SlackAwakeController(c);
    await controller.refresh();
    expect(controller.getSnapshot()).toMatchObject({ phase: "ready", error: null });
    await controller.setAllowance(1800);
    expect(controller.getSnapshot().awake?.allowance_seconds).toBe(1800);
    expect(c.calls).toEqual([
      ["cmux.settings.slack.awake", {}],
      ["cmux.settings.slack.awake", { allowance_seconds: 1800 }],
    ]);
  });

  test("no Chief and a failed save keep their own errors", async () => {
    const noChief = new SlackAwakeController(
      client(() => {
        throw Object.assign(new Error("x"), { code: "cmux.slack.no_chief" });
      }),
    );
    await noChief.refresh();
    expect(noChief.getSnapshot().error).toBe("noChief");
    let fail = false;
    const flaky = new SlackAwakeController(
      client(() => {
        if (fail) throw new Error("http_500");
        return awake;
      }),
    );
    await flaky.refresh();
    fail = true;
    await flaky.setAllowance(0);
    expect(flaky.getSnapshot()).toMatchObject({ phase: "ready", error: "saveFailed" });
    expect(flaky.getSnapshot().awake?.allowance_seconds).toBe(7200);
  });

  test("a bent reply is a read failure", async () => {
    const controller = new SlackAwakeController(client(() => ({ ok: true })));
    await controller.refresh();
    expect(controller.getSnapshot().error).toBe("failed");
  });
});
