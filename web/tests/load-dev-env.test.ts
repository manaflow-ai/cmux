import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const loader = join(webDir, "scripts/load-dev-env.sh");

describe("load-dev-env", () => {
  test("boots local dev auth without a secrets file", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-empty-home-"));
    try {
      const result = sourceLoader(home, {});
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("project=454ecd03-1db2-4050-845e-4ce5b0cd9895");
      expect(result.stdout).toContain("client=pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g");
      expect(result.stdout).toContain("secret=");
      expect(result.stdout).toContain("placeholder=0");
      expect(result.stdout).toContain("secret_file=");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("keeps explicit Stack env values", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-explicit-home-"));
    try {
      const result = sourceLoader(home, {
        NEXT_PUBLIC_STACK_PROJECT_ID: "explicit-project",
        NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "explicit-client",
        STACK_SECRET_SERVER_KEY: "explicit-secret",
      });
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("project=explicit-project");
      expect(result.stdout).toContain("client=explicit-client");
      expect(result.stdout).toContain("secret=explicit-secret");
      expect(result.stdout).toContain("placeholder=0");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("secret-file Stack values override local defaults", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-secret-home-"));
    try {
      const secrets = join(home, ".secrets");
      const file = join(secrets, "cmuxterm-dev.env");
      mkdirSync(secrets, { recursive: true });
      writeFileSync(
        file,
        [
          "NEXT_PUBLIC_STACK_PROJECT_ID=file-project",
          "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=file-client",
          "STACK_SECRET_SERVER_KEY=file-secret",
        ].join("\n"),
      );

      const result = sourceLoader(home, {});
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("project=file-project");
      expect(result.stdout).toContain("client=file-client");
      expect(result.stdout).toContain("secret=file-secret");
      expect(result.stdout).toContain("placeholder=0");
      expect(result.stdout).toContain(`secret_file=${file}`);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("stripe dev reset refuses the local placeholder Stack secret", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-dev-reset-home-"));
    try {
      const secrets = join(home, ".secrets");
      mkdirSync(secrets, { recursive: true });
      writeFileSync(
        join(secrets, "cmuxterm-dev.env"),
        [
          "NEXT_PUBLIC_STACK_PROJECT_ID=454ecd03-1db2-4050-845e-4ce5b0cd9895",
          "STACK_SECRET_SERVER_KEY=cmux-local-dev-placeholder",
        ].join("\n"),
      );

      const bin = join(home, "bin");
      mkdirSync(bin, { recursive: true });
      writeExecutable(join(bin, "curl"), "#!/usr/bin/env sh\nexit 0\n");
      writeExecutable(join(bin, "node"), "#!/usr/bin/env sh\nexit 0\n");
      writeExecutable(
        join(bin, "stripe"),
        "#!/usr/bin/env sh\nprintf 'test_mode_api_key = sk_test_fake\\n'\n",
      );

      const result = spawnSync(
        "bash",
        ["scripts/stripe/dev-reset.sh", "person@example.com"],
        {
          cwd: webDir,
          env: {
            PATH: `${bin}:${process.env.PATH ?? ""}`,
            HOME: home,
            NODE_ENV: process.env.NODE_ENV ?? "test",
          },
          encoding: "utf8",
        },
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("local web dev placeholder is not enough");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("stripe dev reset reports a missing Stack secret without nounset noise", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-dev-reset-missing-secret-home-"));
    try {
      const bin = join(home, "bin");
      mkdirSync(bin, { recursive: true });
      writeExecutable(join(bin, "curl"), "#!/usr/bin/env sh\nexit 0\n");
      writeExecutable(join(bin, "node"), "#!/usr/bin/env sh\nexit 0\n");
      writeExecutable(
        join(bin, "stripe"),
        "#!/usr/bin/env sh\nprintf 'test_mode_api_key = sk_test_fake\\n'\n",
      );

      const result = spawnSync(
        "bash",
        ["scripts/stripe/dev-reset.sh", "person@example.com"],
        {
          cwd: webDir,
          env: {
            PATH: `${bin}:${process.env.PATH ?? ""}`,
            HOME: home,
            NODE_ENV: process.env.NODE_ENV ?? "test",
          },
          encoding: "utf8",
        },
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("STACK_SECRET_SERVER_KEY is required");
      expect(result.stderr).not.toContain("unbound variable");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("stripe dev reset honors an explicit real Stack secret over a placeholder secret file", () => {
    const home = mkdtempSync(join(tmpdir(), "cmux-dev-reset-real-secret-home-"));
    try {
      const secrets = join(home, ".secrets");
      mkdirSync(secrets, { recursive: true });
      writeFileSync(
        join(secrets, "cmuxterm-dev.env"),
        [
          "NEXT_PUBLIC_STACK_PROJECT_ID=454ecd03-1db2-4050-845e-4ce5b0cd9895",
          "STACK_SECRET_SERVER_KEY=cmux-local-dev-placeholder",
        ].join("\n"),
      );

      const bin = join(home, "bin");
      mkdirSync(bin, { recursive: true });
      writeExecutable(join(bin, "curl"), "#!/usr/bin/env sh\nprintf '{\"items\":[]}\\n200\\n'\n");
      writeExecutable(
        join(bin, "stripe"),
        "#!/usr/bin/env sh\nprintf 'test_mode_api_key = sk_test_fake\\n'\n",
      );

      const result = spawnSync(
        "bash",
        ["scripts/stripe/dev-reset.sh", "person@example.com"],
        {
          cwd: webDir,
          env: {
            PATH: `${bin}:${process.env.PATH ?? ""}`,
            HOME: home,
            NODE_ENV: process.env.NODE_ENV ?? "test",
            STACK_SECRET_SERVER_KEY: "real-stack-secret",
          },
          encoding: "utf8",
        },
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("no Stack user found with primary email person@example.com");
      expect(result.stderr).not.toContain("local web dev placeholder is not enough");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

function writeExecutable(path: string, contents: string) {
  writeFileSync(path, contents, { mode: 0o755 });
}

function sourceLoader(
  home: string,
  extraEnv: Record<string, string>,
): { status: number; stdout: string; stderr: string } {
  const result = spawnSync(
    "bash",
    [
      "-c",
      [
        "set -e",
        `source ${loader}`,
        'printf "project=%s\\n" "$NEXT_PUBLIC_STACK_PROJECT_ID"',
        'printf "client=%s\\n" "$NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"',
        'printf "secret=%s\\n" "$STACK_SECRET_SERVER_KEY"',
        'printf "placeholder=%s\\n" "$CMUX_STACK_SECRET_SERVER_KEY_PLACEHOLDER"',
        'printf "secret_file=%s\\n" "$CMUX_WEB_SECRET_ENV_FILE"',
      ].join("; "),
    ],
    {
      cwd: webDir,
      env: {
        PATH: process.env.PATH ?? "",
        HOME: home,
        NODE_ENV: process.env.NODE_ENV ?? "test",
        ...extraEnv,
      },
      encoding: "utf8",
    },
  );
  return {
    status: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}
