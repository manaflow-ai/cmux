import { describe, expect, test } from "bun:test";
import { resolveCoderouterControlContext } from "../services/coderouter/requestContext";
import { VM_AUTHORIZATION_HEADER } from "../services/coderouter/vmAuthorization";

/** Decision 2026-10-03: a machine credential (VM-bound route token, crk_ key) gets no account rights. */
describe("machine tokens and account management", () => {
  const vmIdentity = { teamId: "team-a", stackUserId: "user-1", vmId: "vm-1" };

  for (const [label, headers] of [
    ["VM authorization", { [VM_AUTHORIZATION_HEADER]: "Bearer a.b.c" }],
    ["route token", { authorization: "Bearer crt_live" }],
    ["API key", { authorization: "Bearer crk_live" }],
  ] as const) {
    test(`a ${label} is refused even when it authenticates`, async () => {
      let calls = 0;
      const resolved = await resolveCoderouterControlContext(
        new Request("https://cmux.test/api/coderouter/accounts", { method: "POST", headers }),
        async () => {
          calls++;
          return { ok: true, identity: vmIdentity } as never;
        },
      );
      expect(calls).toBe(1);
      expect(resolved.ok).toBe(false);
      if (resolved.ok) return;
      expect(resolved.response.status).toBe(403);
      expect(await resolved.response.json()).toEqual({ error: "machine_token_cannot_manage_accounts" });
    });
  }

  test("a chatmux machine keeps its own refusal", async () => {
    const resolved = await resolveCoderouterControlContext(
      new Request("https://cmux.test/api/coderouter/accounts", { method: "POST", headers: { authorization: "Bearer crt_x" } }),
      async () => ({ ok: true, identity: { ...vmIdentity, machine: "chatmux" } }) as never,
    );
    expect(resolved.ok).toBe(false);
    if (!resolved.ok) expect(await resolved.response.json()).toEqual({ error: "chatmux_machine_not_allowed" });
  });
});
