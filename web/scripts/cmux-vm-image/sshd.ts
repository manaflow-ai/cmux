/**
 * sshd for LINK-FILES (plans/cmux-next/cloud-automation.md section 5,
 * CLOUD-AUTOMATION D-A4): scp, sftp and rsync reach the VM over the link
 * `ssh` service, which the VM daemon forwards to a loopback sshd. sshd accepts
 * only short-lived OpenSSH user certificates from the CA in the instance
 * binding: a per-user CA for personal machines, the team CA for team machines.
 *
 * The image bakes the policy and empty trust files, so nobody can log in until
 * bind writes the CA public key, the work user's principals and the KRL.
 * No key material is baked.
 */
import { sq } from "./lock";

export const SSH_DIR = "/etc/cmux/ssh";
export const SSH_CA_FILE = `${SSH_DIR}/user-ca.pub`;
export const SSH_PRINCIPALS_DIR = `${SSH_DIR}/principals`;
export const SSH_KRL_FILE = `${SSH_DIR}/revoked.krl`;
export const SSHD_DROP_IN = "/etc/ssh/sshd_config.d/10-cmux.conf";

/** The baked drop-in. Ubuntu's sshd_config includes sshd_config.d/*.conf first, and the first value of a key wins. */
export function sshdDropIn(workUser: string): string {
  return [
    "# cmux: loopback sshd for the link `ssh` service; certificates from the bound CA only.",
    "ListenAddress 127.0.0.1",
    "ListenAddress ::1",
    "PermitRootLogin no",
    "PasswordAuthentication no",
    "KbdInteractiveAuthentication no",
    "PubkeyAuthentication yes",
    "AuthorizedKeysFile none",
    `TrustedUserCAKeys ${SSH_CA_FILE}`,
    `AuthorizedPrincipalsFile ${SSH_PRINCIPALS_DIR}/%u`,
    `RevokedKeys ${SSH_KRL_FILE}`,
    `AllowUsers ${workUser}`,
    "",
  ].join("\n");
}

/** Keys of `sshd -T` output that must have exactly this value. */
function requiredValues(workUser: string): ReadonlyArray<[string, string]> {
  return [
    ["permitrootlogin", "no"],
    ["passwordauthentication", "no"],
    ["kbdinteractiveauthentication", "no"],
    ["pubkeyauthentication", "yes"],
    ["authorizedkeysfile", "none"],
    ["trustedusercakeys", SSH_CA_FILE],
    ["authorizedprincipalsfile", `${SSH_PRINCIPALS_DIR}/%u`],
    ["revokedkeys", SSH_KRL_FILE],
    ["allowusers", workUser],
  ];
}

function parseEffective(text: string): Map<string, string[]> {
  const values = new Map<string, string[]>();
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const space = trimmed.indexOf(" ");
    const key = (space < 0 ? trimmed : trimmed.slice(0, space)).toLowerCase();
    const value = space < 0 ? "" : trimmed.slice(space + 1).trim();
    values.set(key, [...(values.get(key) ?? []), value]);
  }
  return values;
}

const LOOPBACK_LISTEN = /^(127\.0\.0\.1|\[::1\]):\d+$/;

/** Problems in `sshd -T` output against the policy; empty means compliant. */
export function sshdPolicyProblems(effective: string, workUser: string): string[] {
  const values = parseEffective(effective);
  const problems: string[] = [];
  for (const [key, want] of requiredValues(workUser)) {
    const got = values.get(key)?.join(" ");
    if (got === undefined) problems.push(`${key} is missing, want ${want}`);
    else if (got !== want) problems.push(`${key} is ${got}, want ${want}`);
  }
  const listen = values.get("listenaddress") ?? [];
  if (listen.length === 0) problems.push("listenaddress is missing");
  for (const address of listen) if (!LOOPBACK_LISTEN.test(address)) problems.push(`listenaddress ${address} is not loopback`);
  return problems;
}

/** Problems in `ss -Hltn` output: port 22 must listen, and only on loopback (socket activation included). */
export function sshdListenProblems(ss: string): string[] {
  const port22 = ss
    .split("\n")
    .map((line) => line.trim().split(/\s+/)[3])
    .filter((local): local is string => typeof local === "string" && local.endsWith(":22"));
  if (port22.length === 0) return ["nothing listens on port 22"];
  return port22.filter((local) => !LOOPBACK_LISTEN.test(local)).map((local) => `port 22 listens on ${local}`);
}

/**
 * Bake step: the empty trust files, the drop-in check and a restart so the
 * running sshd (or ssh.socket's generator) picks up the loopback listen list.
 * Prints `sshd -T` and `ss -Hltn` for the policy checks above.
 */
export function sshdBakeCommand(workUser: string): string {
  return [
    `install -d -m 0755 ${SSH_DIR} ${SSH_PRINCIPALS_DIR}`,
    `install -m 0644 /dev/null ${SSH_CA_FILE}`,
    `install -m 0644 /dev/null ${SSH_PRINCIPALS_DIR}/${workUser}`,
    `rm -f ${SSH_KRL_FILE} && ssh-keygen -q -k -f ${SSH_KRL_FILE} && chmod 0644 ${SSH_KRL_FILE}`,
    "sshd -t",
    // Ubuntu 24.04 activates sshd through ssh.socket; its generator turns ListenAddress into the socket's listen list.
    "{ systemctl is-enabled --quiet ssh.service || systemctl is-enabled --quiet ssh.socket || systemctl enable --quiet ssh.socket; }",
    "systemctl daemon-reload",
    "{ systemctl is-enabled ssh.socket >/dev/null 2>&1 && systemctl restart ssh.socket; systemctl is-active ssh.service >/dev/null 2>&1 && systemctl restart ssh.service; true; }",
    "echo '--- sshd -T'",
    `sshd -T -C user=${sq(workUser)},host=localhost,addr=127.0.0.1`,
    "echo '--- ss'",
    "ss -Hltn",
  ].join(" && ");
}

/** Splits the bake command's output into its `sshd -T` and `ss` parts. */
export function splitSshdBakeOutput(out: string): { effective: string; ss: string } {
  const effectiveStart = out.indexOf("--- sshd -T");
  const ssStart = out.indexOf("--- ss\n");
  if (effectiveStart < 0 || ssStart < 0) return { effective: "", ss: "" };
  return { effective: out.slice(effectiveStart + "--- sshd -T".length, ssStart), ss: out.slice(ssStart + "--- ss\n".length) };
}

/**
 * Smoke on a clone (never the bake): with the empty baked trust files a
 * certificate login fails; after writing a throwaway CA the way bind will, a
 * certificate login and an scp round trip pass; a KRL entry for the
 * certificate's key id refuses it again. The throwaway CA lives in a temp dir
 * on the clone and is removed, and the trust files are emptied again.
 */
export function sshdCertSmokeCommand(workUser: string): string {
  const ssh = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5";
  const scp = "scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5";
  const id = `-i "$d/user" -o CertificateFile="$d/user-cert.pub"`;
  const target = `${workUser}@127.0.0.1`;
  return [
    "set -e",
    'd="$(mktemp -d)"',
    `trap 'rm -rf "$d"; : > ${SSH_CA_FILE}; : > ${SSH_PRINCIPALS_DIR}/${workUser}; rm -f ${SSH_KRL_FILE}; ssh-keygen -q -k -f ${SSH_KRL_FILE}; chmod 0644 ${SSH_KRL_FILE}; rm -f /tmp/cmux-scp-smoke' EXIT`,
    'ssh-keygen -q -t ed25519 -N "" -f "$d/ca" -C cmux-smoke-ca',
    'ssh-keygen -q -t ed25519 -N "" -f "$d/user" -C cmux-smoke-user',
    `ssh-keygen -q -s "$d/ca" -I cmux-smoke -n ${workUser} -V +5m "$d/user.pub"`,
    `if ${ssh} ${id} ${target} true 2>/dev/null; then echo "FAIL login with an empty CA file"; exit 1; fi; echo "PASS empty CA refuses"`,
    `cp "$d/ca.pub" ${SSH_CA_FILE} && printf '%s\n' ${workUser} > ${SSH_PRINCIPALS_DIR}/${workUser}`,
    `test "$(${ssh} ${id} ${target} echo cert-ok)" = cert-ok && echo "PASS certificate login"`,
    `head -c 1048576 /dev/urandom > "$d/blob" && ${scp} ${id} "$d/blob" ${target}:/tmp/cmux-scp-smoke && cmp "$d/blob" /tmp/cmux-scp-smoke && echo "PASS scp 1 MiB"`,
    `if ${ssh} -i "$d/user" ${target} true 2>/dev/null; then echo "FAIL plain key login"; exit 1; fi; echo "PASS plain key refused"`,
    `printf 'id: cmux-smoke\n' > "$d/krl-spec" && ssh-keygen -q -k -u -f ${SSH_KRL_FILE} -s "$d/ca.pub" "$d/krl-spec"`,
    `if ${ssh} ${id} ${target} true 2>/dev/null; then echo "FAIL revoked certificate login"; exit 1; fi; echo "PASS revoked certificate refused"`,
  ].join("\n");
}
