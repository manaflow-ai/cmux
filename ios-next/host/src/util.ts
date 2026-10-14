// Shared helpers: state directory, config file, logging, PATH discovery.

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";

export const VERSION = "0.1.0";

export function stateDir(): string {
  return process.env.CMUX_NEXT_HOST_HOME || join(homedir(), ".cmux-next-host");
}

export function ensureDir(dir: string): string {
  mkdirSync(dir, { recursive: true });
  return dir;
}

export interface HostConfig {
  api?: string;
  hostId?: string;
  hostToken?: string;
  userId?: string;
  hostName?: string;
}

export function configPath(): string {
  return join(stateDir(), "config.json");
}

export function readConfig(): HostConfig {
  try {
    return JSON.parse(readFileSync(configPath(), "utf8"));
  } catch {
    return {};
  }
}

export function writeConfig(cfg: HostConfig): void {
  const path = configPath();
  ensureDir(dirname(path));
  writeJsonAtomic(path, cfg, 0o600);
  chmodSync(path, 0o600);
}

export function writeJsonAtomic(path: string, value: unknown, mode = 0o644): void {
  ensureDir(dirname(path));
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2), { mode });
  renameSync(tmp, path);
}

export function readJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

/** Normalizes a backend base URL so it ends with /v1 and has no trailing slash. */
export function normalizeApi(url: string): string {
  let u = url.trim().replace(/\/+$/, "");
  if (!/\/v1$/.test(u)) u += "/v1";
  return u;
}

export function newId(prefix: string): string {
  return `${prefix}_${randomBytes(8).toString("hex")}`;
}

export type Logger = (msg: string) => void;

export function makeLogger(scope: string): Logger {
  return (msg: string) => {
    if (process.env.CMUX_NEXT_HOST_QUIET) return;
    process.stderr.write(`${new Date().toISOString()} [${scope}] ${msg}\n`);
  };
}

/**
 * PATH used for child processes. launchd and ssh sessions start with a
 * minimal PATH, so add the usual user tool locations and this node's bin dir.
 */
export function augmentedPath(): string {
  const home = homedir();
  const extra = [
    dirname(process.execPath),
    join(home, ".local", "bin"),
    join(home, ".claude", "local"),
    join(home, ".npm-global", "bin"),
    join(home, ".bun", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ];
  const parts = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const p of extra) if (!parts.includes(p)) parts.push(p);
  return parts.join(delimiter);
}

export function findExecutable(name: string, pathValue = augmentedPath()): string | null {
  for (const dir of pathValue.split(delimiter)) {
    if (!dir) continue;
    const p = join(dir, name);
    if (existsSync(p)) return p;
  }
  return null;
}

export function childEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return { ...process.env, PATH: augmentedPath(), ...extra };
}

const localRequire = createRequire(import.meta.url);

/**
 * Absolute path of a bin script of an npm dependency installed with the host
 * (versions pinned in package.json / package-lock.json). Run it with
 * process.execPath, never through npx.
 */
export function packageBin(pkg: string, bin?: string): string {
  const manifestPath = localRequire.resolve(`${pkg}/package.json`);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { bin?: string | Record<string, string> };
  const rel = typeof manifest.bin === "string" ? manifest.bin : manifest.bin?.[bin ?? Object.keys(manifest.bin ?? {})[0] ?? ""];
  if (!rel) throw new Error(`${pkg} has no bin ${bin ?? ""}`);
  return join(dirname(manifestPath), rel);
}
