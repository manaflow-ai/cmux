import { describe, expect, test } from "bun:test";
import { noAccountConfiguredMessage, OWN_LOGIN_HINT, TEAM_MACHINE_NO_ACCOUNT } from "../services/coderouter/noAccountMessage";

const HOST_CODEX = "No Codex account is configured for this team or shared with this caller. Add one with `cr add codex` or at coderouter.dev.";
const FAMILIES = ["claude", "codex", "opencode"] as const;

describe("coderouter no-account message", () => {
  test("an organization machine says it needs a team account and how to add one, per family", () => {
    const vm = { teamId: "org-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    expect(noAccountConfiguredMessage("codex", vm)).toBe(
      "Codex needs a team account on this machine. To add one for the team, run `cr add codex` in this machine's terminal. If someone added one as private, they can choose Share with team at coderouter.dev.",
    );
    expect(noAccountConfiguredMessage("claude", vm)).toStartWith(`Claude ${TEAM_MACHINE_NO_ACCOUNT}.`);
    expect(noAccountConfiguredMessage("claude", vm)).toContain("`cr add claude`");
    expect(noAccountConfiguredMessage("opencode", vm)).toStartWith(`OpenCode ${TEAM_MACHINE_NO_ACCOUNT}.`);
    expect(noAccountConfiguredMessage("opencode", vm)).toContain("`cr add opencode`");
  });

  test("an organization machine refuses own sign-ins, so its refusal never offers one", () => {
    const vm = { teamId: "org-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    for (const family of FAMILIES) {
      const message = noAccountConfiguredMessage(family, vm);
      expect(message).not.toContain("cr use own");
      expect(message).not.toContain(OWN_LOGIN_HINT[family]);
    }
  });

  test("a personal machine already sees its owner's private accounts, so it is not told to share", () => {
    const personal = { teamId: "user-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    expect(noAccountConfiguredMessage("codex", personal)).toBe(`${HOST_CODEX} ${OWN_LOGIN_HINT.codex}`);
    expect(noAccountConfiguredMessage("codex", personal)).not.toContain(TEAM_MACHINE_NO_ACCOUNT);
  });

  test("a refusal on a personal Cloud machine names both ways out: add an account or use your own sign-in", () => {
    const personal = { teamId: "user-1", stackUserId: "user-1", vmId: "vm-1", poolId: "pool-1" };
    for (const family of FAMILIES) {
      const message = noAccountConfiguredMessage(family, personal);
      expect(message).toContain(`\`cr add ${family}\``);
      expect(message.endsWith(OWN_LOGIN_HINT[family])).toBe(true);
      expect(OWN_LOGIN_HINT[family]).toContain(`\`cr use own ${family}\``);
    }
    // A personal machine is told the command that exists inside it, not the host-only one.
    expect(noAccountConfiguredMessage("claude", personal)).not.toContain("cmux coderouter claude add");
  });

  test("chatmux machines, API keys and people keep the host text", () => {
    const callers = [
      { teamId: "org-1", stackUserId: "user-1", vmId: "vm-1", machine: "chatmux" as const },
      { teamId: "org-1", stackUserId: "user-1", vmId: null, apiKeyId: "key-1" },
      { teamId: "org-1", stackUserId: "user-1", vmId: null },
    ];
    for (const caller of callers) expect(noAccountConfiguredMessage("codex", caller)).toBe(HOST_CODEX);
    for (const caller of callers) {
      for (const family of FAMILIES) expect(noAccountConfiguredMessage(family, caller)).not.toContain("cr use own");
    }
    expect(noAccountConfiguredMessage("claude", callers[2]!)).toBe(
      "No Claude upstream account is configured for this team or shared with this caller. Add one with `cmux coderouter claude add` or at coderouter.dev.",
    );
  });
});
