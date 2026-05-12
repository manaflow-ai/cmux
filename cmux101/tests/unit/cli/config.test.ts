import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtemp, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig, writeConfig } from "@/cli/config";

// We override HOME so that userConfigPath() resolves into our tmpdir.
let tmpHome: string;
let tmpCwd: string;
let origHome: string | undefined;

beforeEach(async () => {
  tmpHome = await mkdtemp(join(tmpdir(), "cmux101-test-home-"));
  tmpCwd = await mkdtemp(join(tmpdir(), "cmux101-test-cwd-"));
  origHome = process.env.HOME;
  process.env.HOME = tmpHome;
});

afterEach(async () => {
  process.env.HOME = origHome;
  await rm(tmpHome, { recursive: true, force: true });
  await rm(tmpCwd, { recursive: true, force: true });
});

describe("loadConfig", () => {
  test("returns default config when no files exist", async () => {
    const config = await loadConfig({ cwd: tmpCwd });
    expect(config.defaultProvider).toBe("anthropic");
    expect(config.defaultModel).toBe("claude-opus-4-7");
    expect(config.providers).toEqual({});
    expect(config.permissions?.allow).toContain("file_read");
    expect(config.permissions?.ask).toContain("shell");
  });

  test("user config is loaded and overrides defaults", async () => {
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    await Bun.write(
      join(userDir, "config.json"),
      JSON.stringify({
        defaultProvider: "openai",
        defaultModel: "gpt-4o",
        providers: { openai: { baseUrl: "https://api.openai.com" } },
      })
    );

    const config = await loadConfig({ cwd: tmpCwd });
    expect(config.defaultProvider).toBe("openai");
    expect(config.defaultModel).toBe("gpt-4o");
    expect(config.providers.openai).toBeDefined();
  });

  test("project config overrides user config where keys collide", async () => {
    // User config: anthropic with model A
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    await Bun.write(
      join(userDir, "config.json"),
      JSON.stringify({
        defaultProvider: "anthropic",
        defaultModel: "claude-sonnet-4-6",
        providers: { anthropic: { configured: true } },
      })
    );

    // Project config: overrides model and adds openai
    const projDir = join(tmpCwd, ".cmux101");
    await mkdir(projDir, { recursive: true });
    await Bun.write(
      join(projDir, "config.json"),
      JSON.stringify({
        defaultModel: "claude-opus-4-7",
        providers: { openai: { configured: true } },
      })
    );

    const config = await loadConfig({ cwd: tmpCwd });
    // Project model wins
    expect(config.defaultModel).toBe("claude-opus-4-7");
    // Provider from user stays
    expect(config.defaultProvider).toBe("anthropic");
    // Both providers present (merged)
    expect(config.providers.anthropic).toBeDefined();
    expect(config.providers.openai).toBeDefined();
  });

  test("explicit configPath overrides project config", async () => {
    const projDir = join(tmpCwd, ".cmux101");
    await mkdir(projDir, { recursive: true });
    await Bun.write(
      join(projDir, "config.json"),
      JSON.stringify({ defaultModel: "claude-sonnet-4-6" })
    );

    const explicitPath = join(tmpCwd, "explicit.json");
    await Bun.write(
      explicitPath,
      JSON.stringify({ defaultModel: "claude-haiku-4-7" })
    );

    const config = await loadConfig({ cwd: tmpCwd, configPath: explicitPath });
    expect(config.defaultModel).toBe("claude-haiku-4-7");
  });

  test("hooks are merged (not replaced) across layers", async () => {
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    await Bun.write(
      join(userDir, "config.json"),
      JSON.stringify({
        hooks: [{ event: "session.start", command: "echo start" }],
      })
    );

    const projDir = join(tmpCwd, ".cmux101");
    await mkdir(projDir, { recursive: true });
    await Bun.write(
      join(projDir, "config.json"),
      JSON.stringify({
        hooks: [{ event: "tool.pre", command: "echo pre" }],
      })
    );

    const config = await loadConfig({ cwd: tmpCwd });
    expect(config.hooks).toHaveLength(2);
  });

  test("invalid config file throws with clear error", async () => {
    const userDir = join(tmpHome, ".cmux101");
    await mkdir(userDir, { recursive: true });
    await Bun.write(
      join(userDir, "config.json"),
      JSON.stringify({ defaultProvider: 42 }) // wrong type
    );

    await expect(loadConfig({ cwd: tmpCwd })).rejects.toThrow(/Invalid config/);
  });
});

describe("writeConfig", () => {
  test("writes user config and can be read back", async () => {
    const config = await loadConfig({ cwd: tmpCwd });
    config.defaultModel = "custom-model";
    await writeConfig(config, "user");

    const reloaded = await loadConfig({ cwd: tmpCwd });
    expect(reloaded.defaultModel).toBe("custom-model");
  });

  test("writes project config and can be read back", async () => {
    const config = await loadConfig({ cwd: tmpCwd });
    config.defaultProvider = "openai";

    // writeConfig uses process.cwd() for project scope; stub it
    const origCwd = process.cwd;
    process.cwd = () => tmpCwd;
    try {
      await writeConfig(config, "project");
    } finally {
      process.cwd = origCwd;
    }

    const reloaded = await loadConfig({ cwd: tmpCwd });
    expect(reloaded.defaultProvider).toBe("openai");
  });
});
