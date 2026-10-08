import { describe, expect, test } from "bun:test";
import {
  CRON_ALLOW_FILE,
  AT_ALLOW_FILE,
  cronAtAllowCommand,
  cronAtAllowProblems,
  SSHD_PAM_LINE,
  SSH_SYNC_UNIT,
  sshSyncUnit,
  SSHD_PRINCIPALS_COMMAND,
  SSH_CA_FILE,
  SSH_KRL_FILE,
  splitSshdBakeOutput,
  sshdDropIn,
  sshdListenProblems,
  sshdPamProblems,
  sshdPolicyProblems,
} from "../scripts/cmux-vm-image/sshd";

// `sshd -T` prints lowercase keys; this is the effective config the drop-in must produce
// (OpenSSH 9.6p1 on the Freestyle Ubuntu 24.04 base, cloud-automation.md section 5).
const GOOD = [
  "port 22",
  "listenaddress 127.0.0.1:22",
  "listenaddress [::1]:22",
  "permitrootlogin no",
  "passwordauthentication no",
  "kbdinteractiveauthentication no",
  "pubkeyauthentication yes",
  "authorizedkeysfile none",
  `trustedusercakeys ${SSH_CA_FILE}`,
  "authorizedprincipalsfile none",
  `authorizedprincipalscommand ${SSHD_PRINCIPALS_COMMAND}`,
  "authorizedprincipalscommanduser nobody",
  `revokedkeys ${SSH_KRL_FILE}`,
  "usepam yes",
  "allowusers cmux",
].join("\n");

const edit = (key: string, value: string | null) =>
  GOOD.split("\n")
    .filter((line) => !line.startsWith(`${key} `))
    .concat(value === null ? [] : [`${key} ${value}`])
    .join("\n");

describe("sshd trusts only the CA from the instance binding (LINK-FILES)", () => {
  test("the effective config of a correct install has no problems", () => {
    expect(sshdPolicyProblems(GOOD, "cmux")).toEqual([]);
  });

  test("password, keyboard-interactive and root logins are refused", () => {
    expect(sshdPolicyProblems(edit("passwordauthentication", "yes"), "cmux")).toContain("passwordauthentication is yes, want no");
    expect(sshdPolicyProblems(edit("kbdinteractiveauthentication", "yes"), "cmux")).toContain("kbdinteractiveauthentication is yes, want no");
    expect(sshdPolicyProblems(edit("permitrootlogin", "prohibit-password"), "cmux")).toContain("permitrootlogin is prohibit-password, want no");
  });

  test("static authorized_keys files are refused; only certificates from the CA file count", () => {
    expect(sshdPolicyProblems(edit("authorizedkeysfile", ".ssh/authorized_keys .ssh/authorized_keys2"), "cmux")).toContain(
      "authorizedkeysfile is .ssh/authorized_keys .ssh/authorized_keys2, want none",
    );
    expect(sshdPolicyProblems(edit("trustedusercakeys", "none"), "cmux")).toContain(`trustedusercakeys is none, want ${SSH_CA_FILE}`);
    expect(sshdPolicyProblems(edit("revokedkeys", null), "cmux")).toContain(`revokedkeys is missing, want ${SSH_KRL_FILE}`);
  });

  test("principals come only from the fail-closed command, never from a static file", () => {
    expect(SSHD_PRINCIPALS_COMMAND).toBe("/opt/cmux/current/bin/cmux host team-ssh principals %u");
    expect(sshdPolicyProblems(edit("authorizedprincipalsfile", "/etc/cmux/ssh/principals/%u"), "cmux")).toContain(
      "authorizedprincipalsfile is /etc/cmux/ssh/principals/%u, want none",
    );
    expect(sshdPolicyProblems(edit("authorizedprincipalscommand", null), "cmux")).toContain(
      `authorizedprincipalscommand is missing, want ${SSHD_PRINCIPALS_COMMAND}`,
    );
    expect(sshdPolicyProblems(edit("authorizedprincipalscommanduser", "root"), "cmux")).toContain("authorizedprincipalscommanduser is root, want nobody");
    expect(sshdPolicyProblems(edit("usepam", "no"), "cmux")).toContain("usepam is no, want yes");
  });

  test("only the work user may log in", () => {
    expect(sshdPolicyProblems(edit("allowusers", null), "cmux")).toContain("allowusers is missing, want cmux");
    expect(sshdPolicyProblems(edit("allowusers", "cmux root"), "cmux")).toContain("allowusers is cmux root, want cmux");
  });

  test("sshd listens on loopback only (the link forwards the ssh service to it)", () => {
    expect(sshdPolicyProblems(GOOD.replace("listenaddress 127.0.0.1:22", "listenaddress 0.0.0.0:22"), "cmux")).toContain("listenaddress 0.0.0.0:22 is not loopback");
    expect(sshdPolicyProblems(GOOD.replace("listenaddress [::1]:22", "listenaddress [::]:22"), "cmux")).toContain("listenaddress [::]:22 is not loopback");
  });

  test("listening sockets: only loopback port 22 passes (ss -Hltn output)", () => {
    expect(sshdListenProblems("LISTEN 0 128 127.0.0.1:22 0.0.0.0:*\nLISTEN 0 128 [::1]:22 [::]:*\nLISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*\n")).toEqual([]);
    expect(sshdListenProblems("LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n")).toEqual(["port 22 listens on 0.0.0.0:22"]);
    expect(sshdListenProblems("LISTEN 0 128 *:22 *:*\n")).toEqual(["port 22 listens on *:22"]);
    expect(sshdListenProblems("LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*\n")).toEqual(["nothing listens on port 22"]);
  });

  test("PAM records every certificate session after logind set the session id (last session line, exactly once)", () => {
    const ubuntu = ["@include common-auth", "account required pam_nologin.so", "@include common-account", "session required pam_loginuid.so", "@include common-session", "@include common-password"];
    expect(sshdPamProblems([...ubuntu, SSHD_PAM_LINE].join("\n"))).toEqual([]);
    expect(sshdPamProblems(ubuntu.join("\n"))).toEqual(["the certificate session recorder is missing from the sshd PAM stack"]);
    expect(sshdPamProblems([...ubuntu, SSHD_PAM_LINE, SSHD_PAM_LINE].join("\n"))).toEqual(["the certificate session recorder appears more than once"]);
    const early = [ubuntu[0], SSHD_PAM_LINE, ...ubuntu.slice(1)];
    expect(sshdPamProblems(early.join("\n"))).toEqual(["the certificate session recorder is not the last session line"]);
    expect(sshdPamProblems(`# ${SSHD_PAM_LINE}\n${ubuntu.join("\n")}`)).toEqual(["the certificate session recorder is missing from the sshd PAM stack"]);
    const readenv = ["session required pam_env.so user_readenv=1", ...ubuntu, SSHD_PAM_LINE];
    expect(sshdPamProblems(readenv.join("\n"))).toEqual(["a PAM module reads the user's environment (user_readenv=1)"]);
  });

  test("the bake output splits into sshd -T, ss and the PAM file; a missing part fails the policy", () => {
    const out = `noise\n--- sshd -T\n${GOOD}\n--- ss\nLISTEN 0 128 127.0.0.1:22 0.0.0.0:*\n--- pam\n${SSHD_PAM_LINE}\n`;
    const parts = splitSshdBakeOutput(out);
    expect(sshdPolicyProblems(parts.effective, "cmux")).toEqual([]);
    expect(sshdListenProblems(parts.ss)).toEqual([]);
    expect(sshdPamProblems(parts.pam)).toEqual([]);
    const cut = splitSshdBakeOutput(out.slice(0, out.indexOf("--- pam")));
    expect(sshdPamProblems(cut.pam)).not.toEqual([]);
  });

  test("the team trust sync unit runs the cmux binary's sync verb and restarts", () => {
    expect(SSH_SYNC_UNIT).toBe("cmux-team-ssh-sync.service");
    expect(sshSyncUnit()).toContain("ExecStart=/opt/cmux/current/bin/cmux host team-ssh sync\n");
    expect(sshSyncUnit()).toContain("Restart=always\n");
  });

  test("the drop-in, read as sshd would, satisfies the policy", () => {
    // sshd -T lowercases keys; ListenAddress gains the port. This mirrors that for the drop-in we bake.
    const effective = sshdDropIn("cmux")
      .split("\n")
      .filter((line) => line.trim() !== "" && !line.startsWith("#"))
      .map((line) => {
        const [key, ...rest] = line.trim().split(/\s+/);
        const value = rest.join(" ");
        if (key.toLowerCase() === "listenaddress") return `listenaddress ${value.includes(":") ? `[${value}]` : value}:22`;
        return `${key.toLowerCase()} ${value}`;
      })
      .join("\n");
    expect(sshdPolicyProblems(effective, "cmux")).toEqual([]);
  });
});

// cx-q4f3: cron and at run a job outside every session scope, so after a revocation nothing would
// end it. Only root and the work user may schedule; every team account is refused by default.
describe("cron and at allowlist", () => {
  test("the bake writes exactly root and the work user to both allow files and prints them", () => {
    const cmd = cronAtAllowCommand("cmux");
    expect(cmd).toContain(CRON_ALLOW_FILE);
    expect(cmd).toContain(AT_ALLOW_FILE);
    expect(CRON_ALLOW_FILE).toBe("/etc/cron.allow");
    expect(AT_ALLOW_FILE).toBe("/etc/at.allow");
  });

  test("the check accepts exactly root and the work user, in both files", () => {
    const good = `--- ${CRON_ALLOW_FILE}\nroot\ncmux\n--- ${AT_ALLOW_FILE}\nroot\ncmux\n`;
    expect(cronAtAllowProblems(good, "cmux")).toEqual([]);
    expect(cronAtAllowProblems(`--- ${CRON_ALLOW_FILE}\nroot\ncmux\nalice-agents\n--- ${AT_ALLOW_FILE}\nroot\ncmux\n`, "cmux")).toEqual([`${CRON_ALLOW_FILE} allows alice-agents`]);
    expect(cronAtAllowProblems(`--- ${CRON_ALLOW_FILE}\nroot\ncmux\n`, "cmux")).toEqual([`${AT_ALLOW_FILE} is missing`]);
    expect(cronAtAllowProblems(`--- ${CRON_ALLOW_FILE}\nroot\n--- ${AT_ALLOW_FILE}\nroot\ncmux\n`, "cmux")).toEqual([`${CRON_ALLOW_FILE} does not allow cmux`]);
  });
});
