// Only the person at the cmux app may allow (hub/person.rs): acpmux refuses an allow from any
// other connection with `data.reason` `permission.person_required` and English for its CLI,
// "approve this on the Mac app: allowing a permission is accepted only from the cmux app, never
// from the CLI, a script or an agent". The pane shows its own sentence for that reason, in the
// pane's language, and never acpmux's words.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { PermissionGroupClient } from "../src/agent-session/acpmux/permissions/client";
import { errorMessage, isHostRefusal } from "../src/agent-session/acpmux/transportErrors";

const ACPMUX_ENGLISH = "approve this on the Mac app";
const refusal = (what: string) =>
  new AcpmuxRpcError({
    code: -32000,
    message: `approve this on the Mac app: ${what} is accepted only from the cmux app, never from the CLI, a script or an agent`,
    data: { reason: "permission.person_required" },
  });

test("a person-required refusal reads as the pane's sentence", () => {
  const text = errorMessage(refusal("allowing a permission"));
  expect(text).toBe(translate("transport.personRequired"));
  expect(text).not.toContain(ACPMUX_ENGLISH);
  // It is a refusal with words the user should see, so a refused pick reports it.
  expect(isHostRefusal(refusal("allowing a permission"))).toBe(true);
});

const memory = new Map<string, unknown>();
const storage = {
  get: (key: string) => memory.get(key),
  set: (key: string, value: unknown) => void memory.set(key, value),
  delete: (key: string) => void memory.delete(key),
};

// The grouped permission panel's error line: an allow acpmux refuses for want of the person.
test("a refused group allow shows the pane's sentence, not acpmux's English", async () => {
  const client = new PermissionGroupClient(
    async (method, params) => {
      if (method === "_acpmux/permission_group_respond") throw refusal("allowing a permission group");
      return {
        groups: [
          {
            groupId: "group-1",
            sessionId: String(params.sessionId),
            turnId: null,
            revision: 1,
            state: "pending",
            items: [{ permissionId: "perm-1", request: { title: "Edit upload.sh" }, state: "pending" }],
            decisions: ["allow_once", "allow_chat", "deny"],
            decision: null,
          },
        ],
        chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
        coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
        batching: { windowMs: 50, maxItems: 8, maxPendingGroups: 4, maxReceipts: 8 },
      };
    },
    () => {},
    storage,
  );
  client.configure(true);
  client.select("chat-person");
  await client.refresh();
  await client.respond("group-1", 1, "allow_once").catch(() => undefined);
  expect(client.state.error).toBe(translate("transport.personRequired"));
  expect(client.state.error).not.toContain(ACPMUX_ENGLISH);
});
