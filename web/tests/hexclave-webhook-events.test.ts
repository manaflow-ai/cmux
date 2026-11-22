import { describe, expect, test } from "bun:test";
import { webhookEvents } from "@hexclave/shared/dist/interface/webhooks";
import { workflowPlatformEventTypes } from "@hexclave/shared/dist/interface/workflows";
import {
  hexclaveWebhookCatalog,
  hexclaveWebhookEventTypes,
  parseHexclaveWebhook,
  type HexclaveWebhookEvent,
  type HexclaveWebhookEventType,
} from "../services/auth/hexclave/webhookEvents";
import { serverTeam, serverUser, TEAM_ID, USER_ID, validWebhookData } from "./helpers/hexclave-fixtures";

const body = (type: string, data: unknown) => JSON.stringify({ type, data });

/** Compile-time exhaustiveness: adding a catalog key without a case fails typecheck at `never`. */
function subjectOf(event: HexclaveWebhookEvent): string {
  switch (event.type) {
    case "user.created":
    case "user.updated":
    case "user.deleted":
    case "team.created":
    case "team.updated":
    case "team.deleted":
      return event.data.id;
    case "team_membership.created":
    case "team_membership.deleted":
    case "team_permission.created":
    case "team_permission.deleted":
    case "project_permission.created":
    case "project_permission.deleted":
      return event.data.user_id;
    default: {
      const unreachable: never = event;
      return unreachable;
    }
  }
}

describe("Hexclave webhook catalog", () => {
  test("covers exactly Hexclave's platform events, including every Svix webhook event", () => {
    expect([...hexclaveWebhookEventTypes].sort()).toEqual([...workflowPlatformEventTypes].sort());
    for (const event of webhookEvents) expect(hexclaveWebhookEventTypes).toContain(event.type as HexclaveWebhookEventType);
  });

  test("uses Hexclave's own event objects, keyed by their wire type", () => {
    for (const [type, event] of Object.entries(hexclaveWebhookCatalog)) expect(event.type).toBe(type);
  });
});

describe("Hexclave webhook validation", () => {
  for (const type of hexclaveWebhookEventTypes) {
    test(`accepts a real-shaped ${type}`, async () => {
      const parsed = await parseHexclaveWebhook(body(type, validWebhookData[type]));
      expect(parsed.kind).toBe("event");
      if (parsed.kind !== "event") return;
      expect(parsed.event.type).toBe(type);
      expect(parsed.event.data).toEqual(validWebhookData[type] as never);
      const data = validWebhookData[type] as { id?: string; user_id?: string };
      const expected = type.startsWith("user.") || type.startsWith("team.") ? data.id : data.user_id;
      expect(subjectOf(parsed.event)).toBe(expected!);
    });
  }

  test("keeps unknown fields so an upstream addition is not an outage", async () => {
    const parsed = await parseHexclaveWebhook(body("user.updated", { ...serverUser(), future_field: { a: 1 } }));
    expect(parsed.kind).toBe("event");
    if (parsed.kind === "event") expect((parsed.event.data as Record<string, unknown>).future_field).toEqual({ a: 1 });
  });

  const malformed: readonly (readonly [string, string, unknown])[] = [
    ["user without id", "user.created", { ...serverUser(), id: undefined }],
    ["user id not a uuid", "user.updated", serverUser({ id: "not-a-uuid" })],
    ["numeric field sent as a string (no coercion)", "user.created", { ...serverUser(), signed_up_at_millis: "1790000000500" }],
    ["boolean sent as a string", "user.created", { ...serverUser(), is_anonymous: "false" }],
    ["restricted flag without a reason", "user.updated", serverUser({ is_restricted: true })],
    ["nested selected team missing display_name", "user.updated", { ...serverUser(), selected_team: { ...serverTeam(), display_name: undefined } }],
    ["user.deleted teams not an array", "user.deleted", { id: USER_ID, teams: "team" }],
    ["user.deleted missing teams", "user.deleted", { id: USER_ID }],
    ["team missing created_at_millis", "team.created", { ...serverTeam(), created_at_millis: undefined }],
    ["team.deleted id not a uuid", "team.deleted", { id: "team-1" }],
    ["membership without user_id", "team_membership.deleted", { team_id: TEAM_ID }],
    ["membership user_id a number", "team_membership.created", { team_id: TEAM_ID, user_id: 7 }],
    ["team permission without team_id", "team_permission.created", { id: "team_member", user_id: USER_ID }],
    ["project permission without id", "project_permission.deleted", { user_id: USER_ID }],
    ["data is an array", "team.updated", []],
    ["data is null", "team.updated", null],
  ];
  for (const [name, type, data] of malformed) {
    test(`rejects ${name}`, async () => {
      const parsed = await parseHexclaveWebhook(body(type, data));
      expect(parsed.kind).toBe("invalid");
      if (parsed.kind === "invalid") {
        expect(parsed.eventType).toBe(type);
        expect(parsed.errors.length).toBeGreaterThan(0);
      }
    });
  }

  test("rejects a body that is not a typed envelope", async () => {
    for (const raw of ["not json", "[]", "null", JSON.stringify({ data: {} }), JSON.stringify({ type: "", data: {} })]) {
      const parsed = await parseHexclaveWebhook(raw);
      expect(parsed).toMatchObject({ kind: "invalid", eventType: null });
    }
  });

  test("reports an unknown type instead of guessing", async () => {
    expect(await parseHexclaveWebhook(body("session.created", { id: USER_ID }))).toEqual({ kind: "unknown", eventType: "session.created" });
    expect(await parseHexclaveWebhook(body("__proto__", {}))).toEqual({ kind: "unknown", eventType: "__proto__" });
  });
});
