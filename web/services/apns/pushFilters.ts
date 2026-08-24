// Per-device push mute filters. A document is authored on the phone, stored
// verbatim on its `device_tokens` row (`push_filters`), and evaluated at
// push-send time so a muted alert degrades to a silent badge-only push (the
// badge stays truthful; nothing visible is shown). Pure and dependency-free so
// both the PUT route and the delivery service share one validator/matcher.

import type { PushPayload } from "./routePolicy";

export const PUSH_FILTERS_VERSION = 1;
/** Rule ceiling per device; a phone UI never needs more and parsing stays O(1)-ish. */
export const MAX_PUSH_FILTER_RULES = 64;
/** Every rule string (id, group id/name, title pattern) is bounded after trim. */
export const MAX_PUSH_FILTER_STRING_CHARS = 200;

/**
 * One mute rule. A rule matches a `notify` push when ALL criteria present on
 * it match; any matching enabled rule mutes the push. `groupId`/`groupName`
 * form one group criterion (either matching suffices), `macDeviceId` scopes a
 * rule to one Mac, and `titlePattern` is a case-insensitive regex search.
 */
export type PushFilterRule = {
  readonly id: string;
  readonly enabled: boolean;
  readonly groupId?: string;
  readonly groupName?: string;
  readonly macDeviceId?: string;
  readonly titlePattern?: string;
};

export type PushFiltersDocument = {
  readonly version: typeof PUSH_FILTERS_VERSION;
  readonly rules: readonly PushFilterRule[];
};

export type PushFiltersResult =
  | { readonly ok: true; readonly value: PushFiltersDocument | null }
  | { readonly ok: false; readonly error: string };

function boundedTrimmedString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (text.length > MAX_PUSH_FILTER_STRING_CHARS) return null;
  return text;
}

/**
 * Validate a stored or client-sent filters document. `null` (or absent) means
 * "no filters" and parses to `null` so a PUT can clear the row. Anything that
 * is not exactly the documented shape is rejected with a typed error; the
 * delivery path treats an unparseable stored document as "deliver" instead.
 */
export function parsePushFilters(value: unknown): PushFiltersResult {
  if (value == null) return { ok: true, value: null };
  if (typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "invalid_filters" };
  }
  const document = value as Record<string, unknown>;
  if (document.version !== PUSH_FILTERS_VERSION) {
    return { ok: false, error: "unsupported_filters_version" };
  }
  if (!Array.isArray(document.rules)) {
    return { ok: false, error: "invalid_filter_rules" };
  }
  if (document.rules.length > MAX_PUSH_FILTER_RULES) {
    return { ok: false, error: "too_many_filter_rules" };
  }

  const rules: PushFilterRule[] = [];
  for (const entry of document.rules) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      return { ok: false, error: "invalid_filter_rule" };
    }
    const raw = entry as Record<string, unknown>;
    const id = boundedTrimmedString(raw.id);
    if (!id) return { ok: false, error: "invalid_filter_rule_id" };
    if (typeof raw.enabled !== "boolean") {
      return { ok: false, error: "invalid_filter_rule_enabled" };
    }
    const criteria: {
      groupId?: string;
      groupName?: string;
      macDeviceId?: string;
      titlePattern?: string;
    } = {};
    for (const key of ["groupId", "groupName", "macDeviceId", "titlePattern"] as const) {
      if (raw[key] == null) continue;
      const text = boundedTrimmedString(raw[key]);
      if (text == null) return { ok: false, error: "filter_rule_string_too_long" };
      if (text) criteria[key] = text;
    }
    if (!criteria.groupId && !criteria.groupName && !criteria.titlePattern) {
      return { ok: false, error: "filter_rule_missing_criteria" };
    }
    rules.push({ id, enabled: raw.enabled, ...criteria });
  }

  return { ok: true, value: { version: PUSH_FILTERS_VERSION, rules } };
}

/**
 * Whether the device's filters mute this push. Only visible `notify` pushes
 * are ever muted (`dismiss` is banner-less housekeeping and must always run).
 * Every uncertainty fails open: a rule with an invalid regex, or criteria the
 * payload cannot satisfy, does not match, so the alert is delivered.
 */
export function isPushMutedByFilters(
  filters: PushFiltersDocument | null,
  payload: PushPayload,
): boolean {
  if (!filters || payload.kind !== "notify") return false;
  return filters.rules.some((rule) => rule.enabled && ruleMatches(rule, payload));
}

function ruleMatches(rule: PushFilterRule, payload: PushPayload): boolean {
  if (rule.macDeviceId) {
    if (!equalsIgnoreCase(rule.macDeviceId, payload.macDeviceId)) return false;
  }
  if (rule.groupId || rule.groupName) {
    const idMatches =
      rule.groupId != null && equalsIgnoreCase(rule.groupId, payload.workspaceGroupId);
    const nameMatches =
      rule.groupName != null
      && equalsIgnoreCase(rule.groupName, payload.workspaceGroupName?.trim() ?? null);
    if (!idMatches && !nameMatches) return false;
  }
  if (rule.titlePattern) {
    if (!titlePatternMatches(rule.titlePattern, payload.title)) return false;
  }
  return true;
}

function equalsIgnoreCase(expected: string, actual: string | null): boolean {
  return actual != null && expected.toLowerCase() === actual.toLowerCase();
}

/** Case-insensitive regex SEARCH; an invalid pattern fails the criterion. */
function titlePatternMatches(pattern: string, title: string): boolean {
  let expression: RegExp;
  try {
    expression = new RegExp(pattern, "iu");
  } catch {
    try {
      expression = new RegExp(pattern, "i");
    } catch {
      return false;
    }
  }
  try {
    return expression.test(title);
  } catch {
    return false;
  }
}
