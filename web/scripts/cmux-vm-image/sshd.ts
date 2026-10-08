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
import { CURRENT_BIN, sq } from "./lock";

export const SSH_DIR = "/etc/cmux/ssh";
export const SSH_CA_FILE = `${SSH_DIR}/user-ca.pub`;
export const SSH_PRINCIPALS_DIR = `${SSH_DIR}/principals`;
export const SSH_KRL_FILE = `${SSH_DIR}/revoked.krl`;
export const SSH_TRUST_FILE = `${SSH_DIR}/trust.json`;
export const SSHD_DROP_IN = "/etc/ssh/sshd_config.d/10-cmux.conf";
export const SSHD_PAM_FILE = "/etc/pam.d/sshd";
/**
 * `cmux host team-ssh` (crate cmux-host, module team_ssh): `principals` prints
 * the principals file's lines only while the last trust sync is at most 120 s
 * old (fail closed), and `session-open` records each certificate session so a
 * revocation can end it.
 */
export const SSH_TRUST_CMD = `${CURRENT_BIN}/cmux host team-ssh`;
export const SSHD_PRINCIPALS_COMMAND = `${SSH_TRUST_CMD} principals %u`;
/**
 * The team trust sync (`cmux host team-ssh sync`): on a team VM that the bind (vm-image.md 6b) gave an
 * install, it reads team_vm.ssh_ca every 30 s and applies it; on every other machine it blocks on
 * inotify until a team binding appears (no wakeups).
 */
export const SSH_SYNC_UNIT = "cmux-team-ssh-sync.service";
export function sshSyncUnit(): string {
  return [
    "[Unit]",
    "Description=cmux team SSH trust sync (idle until the team VM bind)",
    "After=network-online.target",
    "",
    "[Service]",
    `ExecStart=${SSH_TRUST_CMD} sync`,
    "Restart=always",
    "RestartSec=5",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}

/** Runs last in the sshd PAM stack (after pam_systemd sets XDG_SESSION_ID). `required`: an unrecorded certificate session is refused. */
export const SSHD_PAM_LINE = `session required pam_exec.so quiet ${SSH_TRUST_CMD} session-open`;

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
    // Principals come from the command, which reads ${SSH_PRINCIPALS_DIR}/<user> and fails closed when trust is stale.
    "AuthorizedPrincipalsFile none",
    `AuthorizedPrincipalsCommand ${SSHD_PRINCIPALS_COMMAND}`,
    "AuthorizedPrincipalsCommandUser nobody",
    `RevokedKeys ${SSH_KRL_FILE}`,
    "UsePAM yes",
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
    ["authorizedprincipalsfile", "none"],
    ["authorizedprincipalscommand", SSHD_PRINCIPALS_COMMAND],
    ["authorizedprincipalscommanduser", "nobody"],
    ["revokedkeys", SSH_KRL_FILE],
    ["usepam", "yes"],
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
 * Problems in /etc/pam.d/sshd: the session recorder must be present exactly once, as the last session
 * line, and no module may read the user's own PAM environment (`user_readenv=1` would let the user
 * replace SSH_AUTH_INFO_0, which the recorder trusts).
 */
export function sshdPamProblems(pam: string): string[] {
  const lines = pam.split("\n").map((line) => line.trim()).filter((line) => line !== "" && !line.startsWith("#"));
  if (lines.some((line) => /\buser_readenv=1\b/.test(line))) return ["a PAM module reads the user's environment (user_readenv=1)"];
  const hits = lines.filter((line) => line === SSHD_PAM_LINE).length;
  if (hits === 0) return ["the certificate session recorder is missing from the sshd PAM stack"];
  if (hits > 1) return ["the certificate session recorder appears more than once"];
  const sessionLines = lines.filter((line) => line.startsWith("session ") || line.startsWith("@include common-session"));
  return sessionLines[sessionLines.length - 1] === SSHD_PAM_LINE ? [] : ["the certificate session recorder is not the last session line"];
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
    `rm -f ${SSH_KRL_FILE} ${SSH_TRUST_FILE} && ssh-keygen -q -k -f ${SSH_KRL_FILE} && chmod 0644 ${SSH_KRL_FILE}`,
    `{ grep -qxF ${sq(SSHD_PAM_LINE)} ${SSHD_PAM_FILE} || { sed -i -e '$a\\' ${SSHD_PAM_FILE} && printf '%s\\n' ${sq(SSHD_PAM_LINE)} >> ${SSHD_PAM_FILE}; }; }`,
    "sshd -t",
    // Ubuntu 24.04 activates sshd through ssh.socket; its generator turns ListenAddress into the socket's listen list.
    "{ systemctl is-enabled --quiet ssh.service || systemctl is-enabled --quiet ssh.socket || systemctl enable --quiet ssh.socket; }",
    "systemctl daemon-reload",
    "{ systemctl is-enabled ssh.socket >/dev/null 2>&1 && systemctl restart ssh.socket; systemctl is-active ssh.service >/dev/null 2>&1 && systemctl restart ssh.service; true; }",
    "echo '--- sshd -T'",
    `sshd -T -C user=${sq(workUser)},host=localhost,addr=127.0.0.1`,
    "echo '--- ss'",
    "ss -Hltn",
    "echo '--- pam'",
    `cat ${SSHD_PAM_FILE}`,
  ].join(" && ");
}

/** Splits the bake command's output into its `sshd -T`, `ss` and PAM parts. */
export function splitSshdBakeOutput(out: string): { effective: string; ss: string; pam: string } {
  const effectiveStart = out.indexOf("--- sshd -T");
  const ssStart = out.indexOf("--- ss\n");
  const pamStart = out.indexOf("--- pam\n");
  if (effectiveStart < 0 || ssStart < 0 || pamStart < 0) return { effective: "", ss: "", pam: "" };
  return {
    effective: out.slice(effectiveStart + "--- sshd -T".length, ssStart),
    ss: out.slice(ssStart + "--- ss\n".length, pamStart),
    pam: out.slice(pamStart + "--- pam\n".length),
  };
}

/**
 * Smoke on a clone (never the bake), through `cmux host team-ssh` the way a
 * trust sync writes the files: with the empty baked trust files a
 * certificate login fails; after applying a throwaway CA and an empty KRL, a
 * certificate login and an scp round trip pass; a plain key is refused; a
 * newer KRL with the certificate's key id ends the certificate's open session
 * and refuses new ones without an sshd restart; a trust state older than
 * 120 s refuses a valid certificate (fail closed). The throwaway CA lives in a
 * temp dir on the clone and is removed, and the trust files are emptied again.
 */
export function sshdCertSmokeCommand(workUser: string): string {
  const ssh = "ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5";
  const scp = "scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5";
  const id = `-i "$d/user" -o CertificateFile="$d/user-cert.pub"`;
  const id2 = `-i "$d/user2" -o CertificateFile="$d/user2-cert.pub"`;
  const target = `${workUser}@127.0.0.1`;
  const sessions = "/run/cmux-host/ssh-sessions";
  return [
    "set -e",
    'd="$(mktemp -d)"',
    `trap 'kill "$live" 2>/dev/null || true; rm -rf "$d"; : > ${SSH_CA_FILE}; : > ${SSH_PRINCIPALS_DIR}/${workUser}; rm -f ${SSH_KRL_FILE} ${SSH_TRUST_FILE} ${sessions}/*.json; ssh-keygen -q -k -f ${SSH_KRL_FILE}; chmod 0644 ${SSH_KRL_FILE}; rm -f /tmp/cmux-scp-smoke' EXIT`,
    "live=",
    // apply <krl file> <version>: the team_vm.ssh_ca value shape, on stdin.
    `apply() { printf '{"generation":1,"trusted_ca_keys":["%s"],"krl":"%s","krl_version":%s}' "$(cut -d' ' -f1,2 "$d/ca.pub")" "$(base64 -w0 "$1")" "$2" | ${SSH_TRUST_CMD} apply; }`,
    'ssh-keygen -q -t ed25519 -N "" -f "$d/ca" -C cmux-smoke-ca',
    'ssh-keygen -q -t ed25519 -N "" -f "$d/user" -C cmux-smoke-user',
    'ssh-keygen -q -t ed25519 -N "" -f "$d/user2" -C cmux-smoke-user2',
    `ssh-keygen -q -s "$d/ca" -I cmux-smoke -n ${workUser} -z 1 -V +5m "$d/user.pub"`,
    `ssh-keygen -q -s "$d/ca" -I cmux-smoke-2 -n ${workUser} -z 2 -V +5m "$d/user2.pub"`,
    `if ${ssh} ${id} ${target} true 2>/dev/null; then echo "FAIL login with an empty CA file"; exit 1; fi; echo "PASS empty CA refuses"`,
    `printf '%s\\n' ${workUser} > ${SSH_PRINCIPALS_DIR}/${workUser}`,
    'ssh-keygen -q -k -z 1 -f "$d/krl1" && apply "$d/krl1" 1',
    `test "$(${ssh} ${id} ${target} echo cert-ok)" = cert-ok || { echo "FAIL certificate login"; exit 1; }; echo "PASS certificate login"`,
    `{ head -c 1048576 /dev/urandom > "$d/blob" && ${scp} ${id} "$d/blob" ${target}:/tmp/cmux-scp-smoke && cmp "$d/blob" /tmp/cmux-scp-smoke; } || { echo "FAIL scp 1 MiB"; exit 1; }; echo "PASS scp 1 MiB"`,
    // The client loads <identity>-cert.pub on its own, so the plain-key attempt uses a copy with no certificate beside it.
    `install -d -m 0700 "$d/plain" && cp "$d/user" "$d/user.pub" "$d/plain/"`,
    `if ${ssh} -o IdentitiesOnly=yes -i "$d/plain/user" ${target} true 2>/dev/null; then echo "FAIL plain key login"; exit 1; fi; echo "PASS plain key refused"`,
    `${ssh} ${id} ${target} sleep 300 </dev/null >/dev/null 2>&1 & live=$!`,
    `for i in $(seq 50); do grep -qs cmux-smoke ${sessions}/*.json && break; sleep 0.2; done; grep -qs cmux-smoke ${sessions}/*.json || { echo "FAIL session not recorded"; exit 1; }; kill -0 "$live" || { echo "FAIL held session did not stay open"; exit 1; }; echo "PASS session recorded"`,
    `printf 'id: cmux-smoke\\n' > "$d/krl-spec" && ssh-keygen -q -k -z 2 -f "$d/krl2" -s "$d/ca.pub" "$d/krl-spec" && apply "$d/krl2" 2`,
    'for i in $(seq 50); do kill -0 "$live" 2>/dev/null || break; sleep 0.2; done; if kill -0 "$live" 2>/dev/null; then echo "FAIL revoked session still open"; exit 1; fi; echo "PASS revoked session ended"',
    `if ${ssh} ${id} ${target} true 2>/dev/null; then echo "FAIL revoked certificate login"; exit 1; fi; echo "PASS revoked certificate refused"`,
    `test "$(${ssh} ${id2} ${target} echo cert-ok)" = cert-ok || { echo "FAIL unrevoked certificate login"; exit 1; }; echo "PASS unrevoked certificate login"`,
    `printf '{"krl_version":2,"generation":1,"synced_at":%s}' "$(( $(date +%s) - 121 ))" > ${SSH_TRUST_FILE}`,
    `if ${ssh} ${id2} ${target} true 2>/dev/null; then echo "FAIL login with stale trust"; exit 1; fi; echo "PASS stale trust refuses"`,
  ].join("\n");
}
