import { describe, expect, test } from "bun:test";
import { noAccountConfiguredMessage } from "../services/coderouter/noAccountMessage";

const HOST_CODEX = "No Codex account is configured for this team or shared with this caller. Add one with `cr add codex` or at coderouter.dev.";

describe("coderouter no-account message", () => {
  test("an organization machine is told to share or add on the machine, per family", () => {
    const vm = { teamId: "org-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    expect(noAccountConfiguredMessage("codex", vm)).toContain("shared with this Cloud machine's team");
    expect(noAccountConfiguredMessage("codex", vm)).toContain("`cr add codex`");
    expect(noAccountConfiguredMessage("claude", vm)).toContain("`cr add claude`");
    expect(noAccountConfiguredMessage("opencode", vm)).toContain("`cr add opencode`");
  });

  test("a personal machine already sees its owner's private accounts, so it is not told to share", () => {
    const personal = { teamId: "user-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    expect(noAccountConfiguredMessage("codex", personal)).toBe(HOST_CODEX);
  });

  test("chatmux machines, API keys and people keep the host text", () => {
    const callers = [
      { teamId: "org-1", stackUserId: "user-1", vmId: "vm-1", machine: "chatmux" as const },
      { teamId: "org-1", stackUserId: "user-1", vmId: null, apiKeyId: "key-1" },
      { teamId: "org-1", stackUserId: "user-1", vmId: null },
    ];
    for (const caller of callers) expect(noAccountConfiguredMessage("codex", caller)).toBe(HOST_CODEX);
    expect(noAccountConfiguredMessage("claude", callers[2]!)).toBe(
      "No Claude upstream account is configured for this team or shared with this caller. Add one with `cmux coderouter claude add` or at coderouter.dev.",
    );
  });
});
