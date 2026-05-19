import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import {
  actionRecipe,
  normalizeActionRef,
  normalizeActionRunMode,
} from "../services/actions/recipes";
import { runAction } from "../services/actions/runner";

describe("cloud action recipes", () => {
  test("resolves the Stack Auth fresh environment recipe", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");

    expect(recipe?.title).toBe("Fresh Stack Auth environment");
    expect(recipe?.repoUrl).toBe("https://github.com/hexclave/stack-auth.git");
    expect(recipe?.ports.map((port) => port.port)).toEqual([8100, 8101, 8102]);
  });

  test("setup script installs Docker, pnpm, and prepares Stack Auth dependencies", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const script = recipe.setupScript({ ref: "dev", mode: "full" });

    expect(script).toContain("docker.io docker-compose-v2");
    expect(script).toContain("docker compose version");
    expect(script).toContain("systemctl is-active --quiet docker");
    expect(script).toContain("corepack@0.35.0");
    expect(script).not.toContain("corepack@latest");
    expect(script).toContain("corepack prepare pnpm@10.23.0 --activate");
    expect(script).toContain("git clone");
    expect(script).toContain("https://github.com/hexclave/stack-auth.git");
    expect(script).toContain("pnpm build:packages");
    expect(script).toContain("pnpm codegen");
    expect(script).toContain("pnpm run start-deps");
    expect(script).toContain("pnpm run stop-deps");
  });

  test("uses devcontainer lifecycle commands when the repo provides them", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const setupScript = recipe.setupScript({ ref: "dev", mode: "full" });
    const startScript = recipe.startScript({ ref: "dev", mode: "full" });

    expect(setupScript).toContain(".devcontainer/devcontainer.json");
    expect(setupScript).toContain("postCreateCommand");
    expect(startScript).toContain("postStartCommand");
    expect(startScript).toContain("postAttachCommand");
  });

  test("devcontainer lifecycle reader accepts JSONC config files", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const helper = extractDevcontainerReader(recipe.setupScript({ ref: "dev", mode: "full" }));
    const dir = mkdtempSync(join(tmpdir(), "cmux-actions-devcontainer-"));
    try {
      mkdirSync(join(dir, ".devcontainer"));
      writeFileSync(
        join(dir, ".devcontainer", "devcontainer.json"),
        [
          "{",
          "  // devcontainer files are JSONC, not strict JSON",
          "  \"postCreateCommand\": [",
          "    \"echo preparing\",",
          "  ],",
          "}",
        ].join("\n"),
      );
      const helperPath = join(dir, "read-devcontainer-command.mjs");
      const outputPath = join(dir, "postCreateCommand.sh");
      writeFileSync(helperPath, helper);

      const result = spawnSync(process.execPath, [helperPath, "postCreateCommand", outputPath], {
        cwd: dir,
        encoding: "utf8",
      });

      expect(result.stderr).toBe("");
      expect(result.status).toBe(0);
      expect(readFileSync(outputPath, "utf8")).toContain("echo preparing");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("devcontainer lifecycle reader rejects malformed JSONC block comments", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const helper = extractDevcontainerReader(recipe.setupScript({ ref: "dev", mode: "full" }));
    const dir = mkdtempSync(join(tmpdir(), "cmux-actions-devcontainer-"));
    try {
      mkdirSync(join(dir, ".devcontainer"));
      writeFileSync(
        join(dir, ".devcontainer", "devcontainer.json"),
        [
          "{",
          "  \"postCreateCommand\": \"echo preparing\",",
          "  /* unterminated comment",
          "}",
        ].join("\n"),
      );
      const helperPath = join(dir, "read-devcontainer-command.mjs");
      const outputPath = join(dir, "postCreateCommand.sh");
      writeFileSync(helperPath, helper);

      const result = spawnSync(process.execPath, [helperPath, "postCreateCommand", outputPath], {
        cwd: dir,
        encoding: "utf8",
      });

      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("unterminated block comment");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("start script checks out the requested ref and waits for expected ports", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const script = recipe.startScript({ ref: "feature/quote-test", mode: "full" });

    expect(script).toContain("git fetch origin 'feature/quote-test'");
    expect(script).toContain("pnpm run start-deps");
    expect(script).toContain("pnpm run dev:named");
    expect(script).toContain("http://localhost:8100");
    expect(script).toContain("http://localhost:8101");
    expect(script).toContain("http://localhost:8102");
  });

  test("basic mode starts the smaller Stack Auth process set", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const script = recipe.startScript({ ref: "dev", mode: "basic" });

    expect(script).toContain("pnpm run dev:basic");
    expect(script).not.toContain("http://localhost:8100");
    expect(script).toContain("http://localhost:8101");
    expect(script).toContain("http://localhost:8102");
  });

  test("generated setup and start scripts are shell-parseable", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    for (const script of [
      recipe.setupScript({ ref: "dev", mode: "full" }),
      recipe.startScript({ ref: "feature/quote-test", mode: "full" }),
      recipe.startScript({ ref: "dev", mode: "basic" }),
    ]) {
      const result = spawnSync("bash", ["-n"], { input: script, encoding: "utf8" });
      expect(result.stderr).toBe("");
      expect(result.status).toBe(0);
    }
  });

  test("normalizes action inputs", () => {
    expect(normalizeActionRunMode("basic")).toBe("basic");
    expect(normalizeActionRunMode("full")).toBe("full");
    expect(normalizeActionRunMode("other")).toBe("full");
    expect(normalizeActionRef("  main  ", "dev")).toBe("main");
    expect(normalizeActionRef("", "dev")).toBe("dev");
    expect(normalizeActionRef(undefined, "dev")).toBe("dev");
  });

  test("cache name is stable and scoped to the base image", () => {
    const recipe = actionRecipe("hexclave/stack-auth:fresh-env");
    if (!recipe) throw new Error("missing recipe");

    const first = recipe.cacheName({ ref: "dev", mode: "full", baseImage: "base-a" });
    const second = recipe.cacheName({ ref: "dev", mode: "basic", baseImage: "base-a" });
    const third = recipe.cacheName({ ref: "dev", mode: "full", baseImage: "base-b" });

    expect(first).toBe(second);
    expect(first.startsWith("cmux-actions-stack-auth-")).toBe(true);
    expect(third).not.toBe(first);
  });

  test("dry-run resolves scripts without creating a VM", async () => {
    const result = await runAction({
      request: {
        action: "hexclave/stack-auth:fresh-env",
        ref: "dev",
        dryRun: true,
      },
      user: {
        id: "user-actions-dry-run",
        displayName: null,
        primaryEmail: "user@example.com",
        billingCustomerType: "team",
        billingTeamId: "team-actions-dry-run",
        selectedTeamId: "team-actions-dry-run",
        teams: [{ id: "team-actions-dry-run", billingPlanId: "free" }],
        teamIds: ["team-actions-dry-run"],
        userBillingPlanId: null,
        billingPlanId: "free",
      },
    });

    expect(result.dryRun).toBe(true);
    expect(result.vmId).toBeUndefined();
    expect(result.instructions.join("\n")).toContain("cmux actions run hexclave/stack-auth:fresh-env");
  });
});

function extractDevcontainerReader(script: string): string {
  const match = script.match(/cat >\/workspace\/\.cmux-actions\/read-devcontainer-command\.mjs <<'NODE'\n([\s\S]*?)\nNODE/);
  if (!match?.[1]) throw new Error("missing devcontainer reader heredoc");
  return match[1];
}
