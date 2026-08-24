import { describe, expect, test } from "bun:test";
import {
  findPathologicalTitlePattern,
  isPushMutedByFilters,
  MAX_PUSH_FILTER_RULES,
  MAX_PUSH_FILTER_STRING_CHARS,
  parsePushFilters,
  type PushFilterRule,
  type PushFiltersDocument,
} from "../services/apns/pushFilters";
import { parsePushPayload, type PushPayload } from "../services/apns/routePolicy";
import { partitionPushSendTargets } from "../services/apns/pushDeliveryService";
import type { ClaimedApnsTarget } from "../services/apns/deviceDeliveryLease";

function filters(...rules: PushFilterRule[]): PushFiltersDocument {
  return { version: 1, rules };
}

function notifyPayload(overrides: Record<string, unknown> = {}): PushPayload {
  const parsed = parsePushPayload({
    title: "claude",
    body: "Agent finished",
    macDeviceId: "MAC-1",
    workspaceGroupId: "grp-1",
    workspaceGroupName: "Backend Work",
    ...overrides,
  });
  if (!parsed.ok) throw new Error(parsed.error);
  return parsed.value;
}

describe("push filters document", () => {
  test("parses a valid document, trimming rule strings", () => {
    const parsed = parsePushFilters({
      version: 1,
      rules: [
        { id: " rule-1 ", enabled: true, groupId: " grp-1 " },
        {
          id: "rule-2",
          enabled: false,
          groupName: "Backend Work",
          macDeviceId: "mac-1",
          titlePattern: "claude",
        },
      ],
    });

    expect(parsed).toEqual({
      ok: true,
      value: {
        version: 1,
        rules: [
          { id: "rule-1", enabled: true, groupId: "grp-1" },
          {
            id: "rule-2",
            enabled: false,
            groupName: "Backend Work",
            macDeviceId: "mac-1",
            titlePattern: "claude",
          },
        ],
      },
    });
  });

  test("null clears (parses to null); non-objects are rejected", () => {
    expect(parsePushFilters(null)).toEqual({ ok: true, value: null });
    expect(parsePushFilters(undefined)).toEqual({ ok: true, value: null });
    expect(parsePushFilters("mute")).toEqual({ ok: false, error: "invalid_filters" });
    expect(parsePushFilters([])).toEqual({ ok: false, error: "invalid_filters" });
    expect(parsePushFilters({ version: 2, rules: [] })).toEqual({
      ok: false,
      error: "unsupported_filters_version",
    });
    expect(parsePushFilters({ version: 1, rules: {} })).toEqual({
      ok: false,
      error: "invalid_filter_rules",
    });
  });

  test("rejects more rules than the ceiling", () => {
    const rules = Array.from({ length: MAX_PUSH_FILTER_RULES + 1 }, (_, i) => ({
      id: `rule-${i}`,
      enabled: true,
      groupId: "grp-1",
    }));
    expect(parsePushFilters({ version: 1, rules })).toEqual({
      ok: false,
      error: "too_many_filter_rules",
    });
    expect(
      parsePushFilters({ version: 1, rules: rules.slice(0, MAX_PUSH_FILTER_RULES) }).ok,
    ).toBe(true);
  });

  test("rejects oversized strings after trim", () => {
    const long = "x".repeat(MAX_PUSH_FILTER_STRING_CHARS + 1);
    expect(
      parsePushFilters(filters({ id: long, enabled: true, groupId: "grp-1" })),
    ).toEqual({ ok: false, error: "invalid_filter_rule_id" });
    expect(
      parsePushFilters(filters({ id: "rule-1", enabled: true, groupName: long })),
    ).toEqual({ ok: false, error: "filter_rule_string_too_long" });
    // A padded-but-in-bounds string survives because trimming happens first.
    const padded = ` ${"x".repeat(MAX_PUSH_FILTER_STRING_CHARS)} `;
    expect(
      parsePushFilters(filters({ id: "rule-1", enabled: true, titlePattern: padded })).ok,
    ).toBe(true);
  });

  test("rejects a rule without id, boolean enabled, or any criterion", () => {
    expect(
      parsePushFilters({ version: 1, rules: [{ enabled: true, groupId: "grp-1" }] }),
    ).toEqual({ ok: false, error: "invalid_filter_rule_id" });
    expect(
      parsePushFilters({ version: 1, rules: [{ id: "r", enabled: "yes", groupId: "g" }] }),
    ).toEqual({ ok: false, error: "invalid_filter_rule_enabled" });
    // macDeviceId alone only scopes; it is not a mute criterion.
    expect(
      parsePushFilters({ version: 1, rules: [{ id: "r", enabled: true, macDeviceId: "mac-1" }] }),
    ).toEqual({ ok: false, error: "filter_rule_missing_criteria" });
    expect(
      parsePushFilters({ version: 1, rules: [{ id: "r", enabled: true, groupId: "  " }] }),
    ).toEqual({ ok: false, error: "filter_rule_missing_criteria" });
    expect(
      parsePushFilters({ version: 1, rules: ["rule"] }),
    ).toEqual({ ok: false, error: "invalid_filter_rule" });
  });
});

describe("push filter matching", () => {
  test("mutes on workspace-group id (case-insensitive)", () => {
    const doc = filters({ id: "r", enabled: true, groupId: "GRP-1" });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
    expect(isPushMutedByFilters(doc, notifyPayload({ workspaceGroupId: "grp-2" }))).toBe(false);
  });

  test("mutes on workspace-group name, trimmed and case-insensitive", () => {
    const doc = filters({ id: "r", enabled: true, groupName: "backend work" });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
    expect(
      isPushMutedByFilters(doc, notifyPayload({ workspaceGroupName: "Frontend" })),
    ).toBe(false);
  });

  test("group criterion matches on id OR name", () => {
    const doc = filters({
      id: "r",
      enabled: true,
      groupId: "grp-9",
      groupName: "Backend Work",
    });
    // Id misses but name hits.
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
    // Name misses but id hits.
    expect(
      isPushMutedByFilters(
        doc,
        notifyPayload({ workspaceGroupId: "grp-9", workspaceGroupName: "Other" }),
      ),
    ).toBe(true);
    // Neither hits; and a payload without group identity never group-matches.
    expect(
      isPushMutedByFilters(
        doc,
        notifyPayload({ workspaceGroupId: "grp-2", workspaceGroupName: "Other" }),
      ),
    ).toBe(false);
    expect(
      isPushMutedByFilters(
        doc,
        notifyPayload({ workspaceGroupId: undefined, workspaceGroupName: undefined }),
      ),
    ).toBe(false);
  });

  test("macDeviceId scopes a rule to one Mac", () => {
    const doc = filters({
      id: "r",
      enabled: true,
      macDeviceId: "mac-1",
      groupId: "grp-1",
    });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
    expect(isPushMutedByFilters(doc, notifyPayload({ macDeviceId: "mac-2" }))).toBe(false);
    // Payload without a Mac id can never satisfy a Mac-scoped rule.
    expect(isPushMutedByFilters(doc, notifyPayload({ macDeviceId: undefined }))).toBe(false);
  });

  test("title pattern is a case-insensitive regex search", () => {
    const doc = filters({ id: "r", enabled: true, titlePattern: "^CLAUDE" });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
    expect(isPushMutedByFilters(doc, notifyPayload({ title: "codex" }))).toBe(false);
    // Search, not full match.
    const search = filters({ id: "r", enabled: true, titlePattern: "aud" });
    expect(isPushMutedByFilters(search, notifyPayload())).toBe(true);
  });

  test("an invalid title regex fails open (delivers)", () => {
    const doc = filters({ id: "r", enabled: true, titlePattern: "(" });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(false);
    // Even combined with a matching group, the broken criterion fails the rule.
    const combined = filters({
      id: "r",
      enabled: true,
      groupId: "grp-1",
      titlePattern: "(",
    });
    expect(isPushMutedByFilters(combined, notifyPayload())).toBe(false);
  });

  test("a pattern valid only without the u flag still matches via fallback", () => {
    // `\-` is a useless-but-legal escape without `u`, a SyntaxError with it.
    const doc = filters({ id: "r", enabled: true, titlePattern: "cl\\-x|claude" });
    expect(isPushMutedByFilters(doc, notifyPayload())).toBe(true);
  });

  test("disabled rules never match; all criteria on a rule must hold", () => {
    expect(
      isPushMutedByFilters(
        filters({ id: "r", enabled: false, groupId: "grp-1" }),
        notifyPayload(),
      ),
    ).toBe(false);
    expect(
      isPushMutedByFilters(
        filters({ id: "r", enabled: true, groupId: "grp-1", titlePattern: "codex" }),
        notifyPayload(),
      ),
    ).toBe(false);
  });

  test("dismiss pushes are never muted", () => {
    const parsed = parsePushPayload({
      kind: "dismiss",
      notificationIds: ["n-1"],
      macDeviceId: "MAC-1",
      badgeCount: 0,
    });
    if (!parsed.ok) throw new Error(parsed.error);
    const doc = filters(
      { id: "r", enabled: true, titlePattern: ".*" },
      { id: "r2", enabled: true, groupId: "grp-1", groupName: "Backend Work" },
    );
    expect(isPushMutedByFilters(doc, parsed.value)).toBe(false);
    expect(isPushMutedByFilters(null, notifyPayload())).toBe(false);
  });
});

describe("push filter send partition", () => {
  const target = (
    suffix: string,
    pushFilters?: unknown,
  ): ClaimedApnsTarget => ({
    targetId: `target-${suffix}`,
    deviceToken: suffix.repeat(64).slice(0, 64),
    bundleId: "com.cmux.app",
    environment: "production",
    ...(pushFilters === undefined ? {} : { pushFilters }),
  });
  const deliveryPayload = (overrides: Record<string, unknown> = {}) => ({
    ...notifyPayload(overrides),
    correlationId: "4d02de48-a21d-4ba1-97b5-42e9400ee09b",
    expirationEpochSeconds: 1_700_000_120,
  });

  test("splits muted devices onto the badge-only lane, unmuted stay as-is", () => {
    const muted = target("a", filters({ id: "r", enabled: true, groupId: "grp-1" }));
    const unmuted = target("b", filters({ id: "r", enabled: true, groupId: "grp-9" }));
    const bare = target("c");

    const partition = partitionPushSendTargets(
      [muted, unmuted, bare],
      deliveryPayload({ badgeCount: 4 }),
    );

    expect(partition.deliver.map((t) => t.targetId)).toEqual(["target-b", "target-c"]);
    expect(partition.badgeOnly.map((t) => t.targetId)).toEqual(["target-a"]);
    expect(partition.suppressed).toEqual([]);
  });

  test("muted without a badge sends nothing and resolves terminally", () => {
    const muted = target("a", filters({ id: "r", enabled: true, groupId: "grp-1" }));

    const partition = partitionPushSendTargets([muted], deliveryPayload());

    expect(partition.deliver).toEqual([]);
    expect(partition.badgeOnly).toEqual([]);
    expect(partition.suppressed).toEqual([
      {
        targetId: "target-a",
        deviceToken: muted.deviceToken,
        bundleId: "com.cmux.app",
        status: 200,
        reason: "filtered",
        prune: false,
      },
    ]);
  });

  test("an unparseable stored document fails open", () => {
    const corrupt = target("a", { version: 99 });
    const partition = partitionPushSendTargets(
      [corrupt],
      deliveryPayload({ badgeCount: 1 }),
    );
    expect(partition.deliver.map((t) => t.targetId)).toEqual(["target-a"]);
    expect(partition.badgeOnly).toEqual([]);
    expect(partition.suppressed).toEqual([]);
  });
});

describe("pathological title pattern probe", () => {
  const document = (titlePattern: string) => ({
    version: 1,
    rules: [{ id: "rule-1", enabled: true, titlePattern }],
  });

  test("accepts ordinary patterns", () => {
    const parsed = parsePushFilters(document("waiting for .*input"));
    if (!parsed.ok) throw new Error(parsed.error);
    expect(findPathologicalTitlePattern(parsed.value)).toBeNull();
  });

  test("accepts null and pattern-free documents", () => {
    expect(findPathologicalTitlePattern(null)).toBeNull();
    const parsed = parsePushFilters({
      version: 1,
      rules: [{ id: "rule-1", enabled: true, groupId: "g-1" }],
    });
    if (!parsed.ok) throw new Error(parsed.error);
    expect(findPathologicalTitlePattern(parsed.value)).toBeNull();
  });

  test("rejects a catastrophically backtracking pattern", () => {
    const parsed = parsePushFilters(document("(a+)+$"));
    if (!parsed.ok) throw new Error(parsed.error);
    expect(findPathologicalTitlePattern(parsed.value)).toBe("rule-1");
  });
});
