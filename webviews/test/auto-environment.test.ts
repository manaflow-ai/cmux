import { describe, expect, test } from "bun:test";
import { chooseAutoEnvironment } from "../src/agent-session/acpmux/autoEnvironment";

const environments = [
  { id: "local", label: "This Mac", kind: "local" as const },
  { id: "gpu-box", label: "gpu-box", kind: "ssh" as const, connected: true },
  { id: "cloud-1", label: "cloud-1", kind: "cloud" as const, connected: true },
];

describe("new chat Auto environment", () => {
  test("keeps local work local by default", () => {
    expect(chooseAutoEnvironment({ prompt: "Fix the button", environments }).environment.id).toBe("local");
  });

  test("uses a named ready machine from the prompt", () => {
    expect(chooseAutoEnvironment({ prompt: "Run this on gpu-box", environments }).environment.id).toBe("gpu-box");
  });

  test("follows a project's known remote machine", () => {
    expect(
      chooseAutoEnvironment({
        prompt: "Continue the work",
        project: "/home/dev/model",
        environments,
        sessions: [{ cwd: "/home/dev/model", peer: "gpu-box" }],
      }).environment.id,
    ).toBe("gpu-box");
  });

  test("recognizes a cloud request when a cloud machine is ready", () => {
    expect(chooseAutoEnvironment({ prompt: "Start a cloud build", environments }).environment.id).toBe("cloud-1");
  });

  test("does not choose a machine that is unavailable", () => {
    expect(
      chooseAutoEnvironment({
        prompt: "Run this on gpu-box",
        environments: environments.map((environment) =>
          environment.id === "gpu-box" ? { ...environment, connected: false } : environment,
        ),
      }).environment.id,
    ).toBe("local");
  });
});
