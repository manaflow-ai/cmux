import { describe, expect, test } from "bun:test";
import { SSH_CA_FILE, SSH_KRL_FILE, SSH_PRINCIPALS_DIR, sshdDropIn, sshdListenProblems, sshdPolicyProblems } from "../scripts/cmux-vm-image/sshd";

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
  `authorizedprincipalsfile ${SSH_PRINCIPALS_DIR}/%u`,
  `revokedkeys ${SSH_KRL_FILE}`,
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
    expect(sshdPolicyProblems(edit("authorizedprincipalsfile", "none"), "cmux")).toContain(`authorizedprincipalsfile is none, want ${SSH_PRINCIPALS_DIR}/%u`);
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
