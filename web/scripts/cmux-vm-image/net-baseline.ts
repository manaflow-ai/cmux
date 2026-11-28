/**
 * The network baseline the fleet's agent VMs carry (leo-workspace machines/vm-net/, hq docs/rfd/0056), baked
 * into the Cloud VM image so a customer's machine gets it too. Leo, 2026-11-23: "these need to be generalized.
 * to be not just for huge-blue, but for any other [...] vm. that's our sauce."
 *
 * Three pieces, files in images/cmux-vm/net-baseline/:
 * - gai.conf: glibc puts IPv6 first from a ULA source (a Freestyle VM's address behind NAT66). The image keeps
 *   public IPv6 routed on purpose (ipv6-route.ts): there IPv6 is the fast family and IPv4 the lossy one.
 * - BBR as the default congestion control, where the kernel has tcp_bbr. Cubic halves its window at each loss,
 *   so a path that drops a few percent of segments stays slow.
 * - The first SYN is resent after 200 ms, not the kernel's fixed 1 s (syn_retry.py, a 6-instruction sock_ops
 *   program on the root cgroup, loaded with bpf(2) from Python's standard library). On a Freestyle guest
 *   (2026-11-27) 1 or 2 of 150 new GitHub connections waited 1.1-2.5 s for that resend.
 *
 * Clones resume the parked snapshot, so the program attached at bake time is already live in every clone;
 * vm-net-syn-retry.service attaches it again on a cold boot. The DNS part of the fleet baseline is dns.ts here.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const NET_BASELINE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/net-baseline");
export const SYN_RETRY_MS = 200;
export const SYN_RETRY_PATH = "/usr/local/lib/vm-net-baseline/syn_retry.py";
export const SYN_RETRY_UNIT = "vm-net-syn-retry.service";
export const SYN_RETRY_MARK = "/run/vm-net-baseline/syn-retry";
export const GAI_CONF = "/etc/gai.conf";
/** Staged here and moved into sysctl.d and modules-load.d only where the kernel has tcp_bbr. */
export const BBR_STAGE_DIR = "/etc/cmux/net-baseline";
export const BBR_SYSCTL = "/etc/sysctl.d/60-vm-net-bbr.conf";
export const BBR_MODULES = "/etc/modules-load.d/vm-net-bbr.conf";

function source(name: string): string {
  return readFileSync(path.join(NET_BASELINE_DIR, name), "utf8");
}

/** Guest path, text and mode of every file the bake writes before netBaselineBakeCommand runs. */
export function netBaselineFiles(): { path: string; text: string; mode: number }[] {
  return [
    { path: SYN_RETRY_PATH, text: source("syn_retry.py"), mode: 0o755 },
    { path: `/etc/systemd/system/${SYN_RETRY_UNIT}`, text: source("vm-net-syn-retry.service"), mode: 0o644 },
    { path: GAI_CONF, text: source("gai.conf"), mode: 0o644 },
    { path: `${BBR_STAGE_DIR}/60-vm-net-bbr.conf`, text: source("60-vm-net-bbr.conf"), mode: 0o644 },
    { path: `${BBR_STAGE_DIR}/vm-net-bbr.modules`, text: source("vm-net-bbr.modules"), mode: 0o644 },
  ];
}

/**
 * Bake step. BBR goes in where `modprobe tcp_bbr` works or the kernel already lists bbr; else the bake records why
 * and carries on with cubic. The SYN retry is enabled and started, and must then read SYN_RETRY_MS: a kernel that
 * cannot take it (no cgroup v2, HZ unknown) fails the bake, since the smoke would fail every clone anyway.
 * Prints `bbr=on|off (...)`, `syn-retry=attached N` and `gai=ipv6-first`.
 */
export function netBaselineBakeCommand(): string {
  const avail = "/proc/sys/net/ipv4/tcp_available_congestion_control";
  return [
    `if modprobe tcp_bbr 2>/dev/null || grep -qw bbr ${avail}; then install -m 0644 ${BBR_STAGE_DIR}/60-vm-net-bbr.conf ${BBR_SYSCTL} && install -m 0644 ${BBR_STAGE_DIR}/vm-net-bbr.modules ${BBR_MODULES} && sysctl -q -p ${BBR_SYSCTL} && echo "bbr=on ($(sysctl -n net.ipv4.tcp_congestion_control))"; else echo "bbr=off (kernel $(uname -r) has no tcp_bbr: $(cat ${avail}))"; fi`,
    `systemctl daemon-reload && systemctl enable ${SYN_RETRY_UNIT} >/dev/null 2>&1 && systemctl restart ${SYN_RETRY_UNIT}`,
    `test "$(cat ${SYN_RETRY_MARK})" = ${SYN_RETRY_MS} || { journalctl -u ${SYN_RETRY_UNIT} --no-pager -n 5; exit 1; }`,
    `echo "syn-retry=$(python3 -I ${SYN_RETRY_PATH} status)"`,
    `grep -qx 'label fc00::/7 1' ${GAI_CONF} && echo gai=ipv6-first`,
  ].join(" && ");
}

/** Smoke step on a clone: what each piece reads now, one `key=value` line each. */
export function netBaselineSmokeCommand(): string {
  return [
    `echo "syn-retry=$(python3 -I ${SYN_RETRY_PATH} status 2>&1)"`,
    `echo "syn-retry-mark=$(cat ${SYN_RETRY_MARK} 2>/dev/null || echo absent)"`,
    `echo "bbr-baked=$(test -f ${BBR_SYSCTL} && echo yes || echo no)"`,
    `echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>&1)"`,
    `echo "gai=$(grep -qx 'label fc00::/7 1' ${GAI_CONF} 2>/dev/null && echo ipv6-first || echo default)"`,
  ].join("; ");
}

/** Problems in netBaselineSmokeCommand output; none when every baked piece is live. */
export function netBaselineProblems(stdout: string): string[] {
  const seen = new Map(
    stdout.trim().split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()] as const),
  );
  const problems: string[] = [];
  if (seen.get("syn-retry") !== `attached ${SYN_RETRY_MS}`) {
    problems.push(`first-SYN retry: ${seen.get("syn-retry") ?? "no answer"} (want attached ${SYN_RETRY_MS}; a lost SYN costs 1 s without it)`);
  }
  if (seen.get("bbr-baked") === "yes" && seen.get("cc") !== "bbr") problems.push(`congestion control is ${seen.get("cc") ?? "unknown"}, but the image baked BBR`);
  if (seen.get("gai") !== "ipv6-first") problems.push(`${GAI_CONF} does not put IPv6 first from a ULA source`);
  return problems;
}
