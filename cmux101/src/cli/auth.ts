/**
 * Credential management for cmux101.
 *
 * Platform detection:
 *   macOS  → KeychainCredentialStore (security)
 *   Linux  → KeychainCredentialStore (secret-tool)
 *   other  → FileCredentialStore
 *
 * Falls back to FileCredentialStore if the platform binary is not found.
 */

import { join } from "node:path";
import { mkdir, chmod } from "node:fs/promises";
import { loadConfig, writeConfig } from "./config";

const SERVICE_NAME = "cmux101";

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

export interface CredentialStore {
  get(provider: string): Promise<string | null>;
  set(provider: string, value: string): Promise<void>;
  remove(provider: string): Promise<void>;
}

// ---------------------------------------------------------------------------
// KeychainCredentialStore
// ---------------------------------------------------------------------------

export class KeychainCredentialStore implements CredentialStore {
  private platform: NodeJS.Platform;

  constructor(platform: NodeJS.Platform = process.platform) {
    this.platform = platform;
  }

  async get(provider: string): Promise<string | null> {
    try {
      if (this.platform === "darwin") {
        const proc = Bun.spawnSync([
          "security",
          "find-generic-password",
          "-s", SERVICE_NAME,
          "-a", provider,
          "-w",
        ]);
        if (proc.exitCode !== 0) return null;
        return proc.stdout.toString().trim() || null;
      } else {
        // Linux: secret-tool
        const proc = Bun.spawnSync([
          "secret-tool",
          "lookup",
          "service", SERVICE_NAME,
          "account", provider,
        ]);
        if (proc.exitCode !== 0) return null;
        return proc.stdout.toString().trim() || null;
      }
    } catch {
      return null;
    }
  }

  async set(provider: string, value: string): Promise<void> {
    if (this.platform === "darwin") {
      // Delete existing entry first (ignore errors)
      Bun.spawnSync([
        "security",
        "delete-generic-password",
        "-s", SERVICE_NAME,
        "-a", provider,
      ]);
      const proc = Bun.spawnSync([
        "security",
        "add-generic-password",
        "-s", SERVICE_NAME,
        "-a", provider,
        "-w", value,
      ]);
      if (proc.exitCode !== 0) {
        throw new Error(
          `Keychain set failed: ${proc.stderr.toString().trim()}`
        );
      }
    } else {
      const proc = Bun.spawn(
        [
          "secret-tool",
          "store",
          "--label", `${SERVICE_NAME}/${provider}`,
          "service", SERVICE_NAME,
          "account", provider,
        ],
        {
          stdin: new TextEncoder().encode(value),
        }
      );
      const exitCode = await proc.exited;
      if (exitCode !== 0) {
        throw new Error(`secret-tool store failed with exit code ${exitCode}`);
      }
    }
  }

  async remove(provider: string): Promise<void> {
    if (this.platform === "darwin") {
      Bun.spawnSync([
        "security",
        "delete-generic-password",
        "-s", SERVICE_NAME,
        "-a", provider,
      ]);
    } else {
      Bun.spawnSync([
        "secret-tool",
        "clear",
        "service", SERVICE_NAME,
        "account", provider,
      ]);
    }
  }
}

// ---------------------------------------------------------------------------
// FileCredentialStore
// ---------------------------------------------------------------------------

function credentialsFilePath(): string {
  const home = process.env.HOME ?? process.env.USERPROFILE ?? "~";
  return join(home, ".cmux101", "credentials.json");
}

export class FileCredentialStore implements CredentialStore {
  private filePath: string;

  constructor(filePath?: string) {
    this.filePath = filePath ?? credentialsFilePath();
  }

  private async readAll(): Promise<Record<string, string>> {
    try {
      const file = Bun.file(this.filePath);
      const exists = await file.exists();
      if (!exists) return {};
      const text = await file.text();
      return JSON.parse(text) as Record<string, string>;
    } catch {
      return {};
    }
  }

  private async writeAll(data: Record<string, string>): Promise<void> {
    const dir = this.filePath.substring(0, this.filePath.lastIndexOf("/"));
    await mkdir(dir, { recursive: true });
    await Bun.write(this.filePath, JSON.stringify(data, null, 2) + "\n");
    // chmod 600
    await chmod(this.filePath, 0o600);
  }

  async get(provider: string): Promise<string | null> {
    const data = await this.readAll();
    return data[provider] ?? null;
  }

  async set(provider: string, value: string): Promise<void> {
    const data = await this.readAll();
    data[provider] = value;
    await this.writeAll(data);
  }

  async remove(provider: string): Promise<void> {
    const data = await this.readAll();
    delete data[provider];
    await this.writeAll(data);
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function chooseCredentialStore(): CredentialStore {
  if (process.platform === "darwin") {
    const bin = Bun.which("security");
    if (bin) return new KeychainCredentialStore("darwin");
    console.warn(
      "[cmux101] 'security' binary not found; falling back to file-based credential store."
    );
    return new FileCredentialStore();
  }

  if (process.platform === "linux") {
    const bin = Bun.which("secret-tool");
    if (bin) return new KeychainCredentialStore("linux");
    console.warn(
      "[cmux101] 'secret-tool' not found; falling back to file-based credential store."
    );
    return new FileCredentialStore();
  }

  if (process.platform === "win32") {
    const bin = Bun.which("wincred.exe");
    if (bin) return new KeychainCredentialStore("win32");
    console.warn(
      "[cmux101] 'wincred.exe' not found; falling back to file-based credential store."
    );
    return new FileCredentialStore();
  }

  console.warn(
    `[cmux101] Unsupported platform '${process.platform}'; using file-based credential store.`
  );
  return new FileCredentialStore();
}

// ---------------------------------------------------------------------------
// Public auth helpers
// ---------------------------------------------------------------------------

let _store: CredentialStore | null = null;

function getStore(): CredentialStore {
  if (!_store) _store = chooseCredentialStore();
  return _store;
}

export async function login(provider: string, key: string): Promise<void> {
  const store = getStore();
  await store.set(provider, key);

  // Mark provider as configured in user config
  const config = await loadConfig();
  if (!config.providers[provider]) {
    config.providers[provider] = {};
  }
  (config.providers[provider] as Record<string, unknown>)["configured"] = true;
  await writeConfig(config, "user");
}

export async function logout(provider: string): Promise<void> {
  const store = getStore();
  await store.remove(provider);
}

export async function getApiKey(provider: string): Promise<string | null> {
  // Check env var first: e.g. ANTHROPIC_API_KEY, OPENAI_API_KEY
  const envKey = `${provider.toUpperCase().replace(/-/g, "_")}_API_KEY`;
  const fromEnv = process.env[envKey];
  if (fromEnv) return fromEnv;

  // Fall back to credential store
  const store = getStore();
  return store.get(provider);
}
