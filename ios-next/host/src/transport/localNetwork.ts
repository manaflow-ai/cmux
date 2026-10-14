// Local Network Privacy self-check (macOS).
//
// macOS denies LAN traffic to a process that has no Local Network grant and is
// not attributed to a process that has one (Terminal, an ssh session). A host
// started with nohup from ssh that has since logged out, or as a LaunchAgent,
// gets EHOSTUNREACH on every UDP send to a LAN address while internet and
// Tailscale addresses still work. ICE then cannot answer the phone's LAN
// checks and every link ends on the TURN relay. This check sends one datagram
// to the default gateway so the log says why, instead of silently relaying.

import { execFile } from "node:child_process";
import { createSocket } from "node:dgram";
import { isIPv4 } from "node:net";

export type LocalNetworkStatus =
  | { state: "ok"; target: string }
  | { state: "blocked"; target: string; code: string }
  | { state: "unknown"; reason: string };

/** Parse `route -n get default` output for an IPv4 gateway. */
export function parseDefaultGateway(out: string): string | undefined {
  const m = /^\s*gateway:\s*(\S+)\s*$/m.exec(out);
  return m && isIPv4(m[1]) ? m[1] : undefined;
}

export type SendProbe = (target: string) => Promise<string | undefined>;

/** Sends one byte to target:9 (discard). Resolves an error code, or undefined on success. */
export const udpSendProbe: SendProbe = (target) =>
  new Promise((resolve) => {
    const sock = createSocket("udp4");
    sock.on("error", () => {});
    sock.send(Buffer.from([0]), 9, target, (err) => {
      sock.close();
      resolve(err ? ((err as NodeJS.ErrnoException).code ?? err.message) : undefined);
    });
  });

function defaultGateway(): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("/sbin/route", ["-n", "get", "default"], { timeout: 3000 }, (err, stdout) => resolve(err ? undefined : parseDefaultGateway(stdout)));
  });
}

const BLOCKED = new Set(["EHOSTUNREACH", "EPERM", "EACCES"]);

export async function checkLocalNetwork(opts: { gateway?: () => Promise<string | undefined>; send?: SendProbe; platform?: string } = {}): Promise<LocalNetworkStatus> {
  if ((opts.platform ?? process.platform) !== "darwin") return { state: "unknown", reason: "not macOS" };
  const target = await (opts.gateway ?? defaultGateway)();
  if (!target) return { state: "unknown", reason: "no IPv4 default gateway" };
  const code = await (opts.send ?? udpSendProbe)(target);
  if (!code) return { state: "ok", target };
  return BLOCKED.has(code) ? { state: "blocked", target, code } : { state: "unknown", reason: `send to ${target} failed: ${code}` };
}

export function describeLocalNetwork(s: LocalNetworkStatus): string {
  switch (s.state) {
    case "ok":
      return `local network: ok (UDP to gateway ${s.target})`;
    case "unknown":
      return `local network: not checked (${s.reason})`;
    case "blocked":
      return (
        `local network: BLOCKED (UDP to gateway ${s.target} failed: ${s.code}). ` +
        "macOS Local Network Privacy is denying this process, so phones on this LAN cannot reach it directly and links fall back to the TURN relay. " +
        `Allow "node" in System Settings > Privacy & Security > Local Network, or run the host from a Terminal or a live ssh session.`
      );
  }
}
