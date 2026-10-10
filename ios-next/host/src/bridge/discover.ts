// Finds the running cmux-next app's daemon socket and its acpmux socket.
//
// Daemon: the app runs `cmux-tui --session cmux-app[-<tag>]` with TMPDIR set
// to the Darwin per-user temp dir, so the socket is
// `$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-<uid>/cmux-app[-<tag>].sock`
// (spec/transports.md, DaemonLauncher.swift). acpmux: `~/.acpmux/acpmux.sock`
// for a release build, `~/.acpmux/tags/<tag>/acpmux.sock` for a tagged one
// (AcpmuxEnvironment.swift). Explicit paths win.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import net from "node:net";
import { homedir, tmpdir, userInfo } from "node:os";
import { join } from "node:path";

export interface BridgeTargets {
  daemonSocket: string | null;
  /** "cmux-app" or "cmux-app-<tag>". */
  session: string | null;
  acpmuxSocket: string | null;
}

export function darwinUserTempDir(): string {
  try {
    return execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
  } catch {
    return tmpdir();
  }
}

function isSocket(p: string): boolean {
  try {
    return statSync(p).isSocket();
  } catch {
    return false;
  }
}

/** Resolves when something accepts connections on the socket. */
export function socketAlive(p: string, timeoutMs = 1_000): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.createConnection(p);
    const done = (ok: boolean) => {
      s.destroy();
      resolve(ok);
    };
    const timer = setTimeout(() => done(false), timeoutMs);
    s.once("connect", () => {
      clearTimeout(timer);
      done(true);
    });
    s.once("error", () => {
      clearTimeout(timer);
      done(false);
    });
  });
}

/** Candidate app daemon sockets, best first: release `cmux-app`, then the newest tagged one. */
export function daemonSocketCandidates(): { path: string; session: string }[] {
  const uid = userInfo().uid;
  const dirs = [...new Set([join(darwinUserTempDir(), `cmux-tui-${uid}`), join(process.env.TMPDIR ?? tmpdir(), `cmux-tui-${uid}`), `/tmp/cmux-tui-${uid}`])];
  const out: { path: string; session: string; mtime: number }[] = [];
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    for (const name of readdirSync(dir)) {
      const m = /^(cmux-app(?:-[A-Za-z0-9._-]+)?)\.sock$/.exec(name);
      const p = join(dir, name);
      if (!m || !isSocket(p)) continue;
      out.push({ path: p, session: m[1]!, mtime: statSync(p).mtimeMs });
    }
  }
  return out.sort((a, b) => Number(b.session === "cmux-app") - Number(a.session === "cmux-app") || b.mtime - a.mtime);
}

export function acpmuxSocketFor(session: string | null): string {
  const tag = session && session !== "cmux-app" ? session.slice("cmux-app-".length) : null;
  const home = tag ? join(homedir(), ".acpmux", "tags", tag) : join(homedir(), ".acpmux");
  return join(home, "acpmux.sock");
}

export async function discoverTargets(explicit: { daemonSocket?: string; acpmuxSocket?: string } = {}): Promise<BridgeTargets> {
  let daemonSocket: string | null = null;
  let session: string | null = null;
  const wantDaemon = explicit.daemonSocket ?? process.env.CMUX_NEXT_DAEMON_SOCKET;
  if (wantDaemon) {
    daemonSocket = (await socketAlive(wantDaemon)) ? wantDaemon : null;
    const m = /(cmux-app(?:-[A-Za-z0-9._-]+)?)\.sock$/.exec(wantDaemon);
    session = m ? m[1]! : null;
  } else {
    for (const c of daemonSocketCandidates()) {
      if (await socketAlive(c.path)) {
        daemonSocket = c.path;
        session = c.session;
        break;
      }
    }
  }
  const wantAcpmux = explicit.acpmuxSocket ?? process.env.CMUX_NEXT_ACPMUX_SOCKET ?? (daemonSocket ? acpmuxSocketFor(session) : undefined);
  const acpmuxSocket = wantAcpmux && isSocket(wantAcpmux) && (await socketAlive(wantAcpmux)) ? wantAcpmux : null;
  return { daemonSocket, session, acpmuxSocket };
}
