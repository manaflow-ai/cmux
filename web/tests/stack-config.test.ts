import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";

const baseEnv = {
  PATH: process.env.PATH ?? "",
  HOME: process.env.HOME ?? "",
  SKIP_ENV_VALIDATION: "1",
  RESEND_API_KEY: "test-resend",
  CMUX_FEEDBACK_FROM_EMAIL: "hello@example.com",
  CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rule",
  NEXT_PUBLIC_STACK_PROJECT_ID: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "stack-public",
};

describe("Stack configuration", () => {
  test("keeps public handler config separate from server Stack config", () => {
    const result = probeStackConfig(baseEnv);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("server=false");
    expect(result.stdout).toContain("serverApp=false");
    expect(result.stdout).toContain("handler=true");
    expect(result.stdout).toContain("handlerApp=true");
  });

  test("treats a real server secret as server Stack config", () => {
    const result = probeStackConfig({
      ...baseEnv,
      STACK_SECRET_SERVER_KEY: "stack-secret",
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("server=true");
    expect(result.stdout).toContain("serverApp=true");
    expect(result.stdout).toContain("handler=true");
    expect(result.stdout).toContain("handlerApp=true");
  });
});

function probeStackConfig(env: Record<string, string>): {
  exitCode: number;
  stdout: string;
  stderr: string;
} {
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      [
        "const stack = await import('./app/lib/stack');",
        "console.log(`server=${stack.isStackConfigured()}`);",
        "console.log(`serverApp=${Boolean(stack.stackServerApp)}`);",
        "console.log(`handler=${stack.isStackHandlerConfigured()}`);",
        "console.log(`handlerApp=${Boolean(stack.stackHandlerApp)}`);",
      ].join(" "),
    ],
    {
      env: env as NodeJS.ProcessEnv,
      encoding: "utf8",
    },
  );
  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}
