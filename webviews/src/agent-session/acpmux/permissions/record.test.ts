// l10n-allow-file: test fixture option names, not shipped UI.
// How a single permission card's answer reads in its receipt (record.ts): by the option's ACP kind,
// else as the card itself reads an option (PermissionCard.tsx `permissionOptionKind`), and never
// "Allowed" for an option neither can place.
import { describe, expect, test } from "bun:test";
import type { AcpmuxPermission } from "../model";
import { permissionDecision } from "./record";

const ask = (options: { id: string; name: string; kind?: string }[]): AcpmuxPermission => ({
  permissionId: "p1",
  title: "Run npm test",
  pending: true,
  options: options.map((option) => ({ ...option, allow: false })),
});
const picked = (optionId: string) => ({ outcome: "selected", optionId });

describe("permissionDecision", () => {
  test("by ACP kind", () => {
    const permission = ask([
      { id: "approved", name: "Approve", kind: "allow_once" },
      { id: "approved-for-session", name: "Approve for this session", kind: "allow_always" },
      { id: "denied", name: "Decline", kind: "reject_once" },
      { id: "abort", name: "Cancel", kind: "reject_always" },
    ]);
    expect(permissionDecision(permission, picked("approved"))).toEqual({ kind: "allowed" });
    expect(permissionDecision(permission, picked("approved-for-session"))).toEqual({ kind: "allowedAlways" });
    expect(permissionDecision(permission, picked("denied"))).toEqual({ kind: "denied" });
    expect(permissionDecision(permission, picked("abort"))).toEqual({ kind: "denied" });
    expect(permissionDecision(permission, { outcome: "cancelled" })).toEqual({ kind: "cancelled" });
  });

  test("without a kind, as the card reads the option", () => {
    const permission = ask([
      { id: "allow", name: "Allow once for this chat" },
      { id: "always", name: "Always allow" },
      { id: "reject", name: "Reject" },
    ]);
    expect(permissionDecision(permission, picked("allow"))).toEqual({ kind: "allowed" });
    expect(permissionDecision(permission, picked("always"))).toEqual({ kind: "allowedAlways" });
    expect(permissionDecision(permission, picked("reject"))).toEqual({ kind: "denied" });
  });

  test("an option neither can place is named, never called allowed", () => {
    const permission = ask([
      { id: "no", name: "No" },
      { id: "plan", name: "Keep planning", kind: "custom" },
    ]);
    expect(permissionDecision(permission, picked("no"))).toEqual({ kind: "answered", option: "No" });
    expect(permissionDecision(permission, picked("plan"))).toEqual({ kind: "answered", option: "Keep planning" });
    expect(permissionDecision(permission, picked("gone"))).toEqual({ kind: "answered", option: "gone" });
  });
});
