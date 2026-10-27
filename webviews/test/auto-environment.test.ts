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
        projectPeer: "gpu-box",
        environments,
        sessions: [{ cwd: "/home/dev/model", peer: "gpu-box" }],
      }),
    ).toMatchObject({ environment: { id: "gpu-box" }, cwd: "/home/dev/model" });
  });

  test("does not forward a local project path to a prompt-selected remote", () => {
    const choice = chooseAutoEnvironment({
      prompt: "Start a cloud build",
      project: "/Users/alice/src/app",
      environments,
    });
    expect(choice.environment.id).toBe("cloud-1");
    expect(choice.cwd).toBeUndefined();
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

  test("explicit local intent wins over remote keywords", () => {
    expect(chooseAutoEnvironment({ prompt: "Build the macOS app locally", environments }).environment.id).toBe("local");
  });

  test("requires a complete machine-name reference", () => {
    expect(
      chooseAutoEnvironment({
        prompt: "Improve the developer documentation",
        environments: [...environments, { id: "dev", label: "dev", kind: "ssh", connected: true }],
      }).environment.id,
    ).toBe("local");
  });

  test("keeps a known project folder when the prompt names its machine", () => {
    expect(
      chooseAutoEnvironment({
        prompt: "Continue the work on gpu-box",
        project: "/home/dev/model",
        environments,
        sessions: [{ cwd: "/home/dev/model", peer: "gpu-box" }],
      }),
    ).toMatchObject({ environment: { id: "gpu-box" }, cwd: "/home/dev/model" });
  });
});

test("resolves the folder on the named destination when peers share a project path", () => {
  expect(
    chooseAutoEnvironment({
      prompt: "Continue on gpu-box",
      project: "/repo",
      environments,
      sessions: [
        { peer: "cloud-1", cwd: "/repo" },
        { peer: "gpu-box", cwd: "/repo" },
      ],
    }),
  ).toMatchObject({ environment: { id: "gpu-box" }, cwd: "/repo" });
});

test.each([
  "Fix the build error in this repo",
  "Fix the server startup",
  "Update the cloud documentation",
  "Do not run this in the cloud",
  "Don't run this on gpu-box",
  "Never deploy to the cloud",
  "Run tests without using the cloud",
  "Fix the bug mentioning gpu-box",
])("keeps an ordinary or negated instruction local: %s", (prompt) => {
  expect(chooseAutoEnvironment({ prompt, project: "/Users/alice/src/app", environments }).environment.id).toBe("local");
});

test.each([false, true])(
  "a remote path match cannot take ownership of a local project (local session: %s)",
  (localSession) => {
    const project = "/Users/alice/src/app";
    const sessions = [
      { cwd: project, peer: "gpu-box" },
      ...(localSession ? [{ cwd: project, hostKind: "local" }] : []),
    ];
    expect(chooseAutoEnvironment({ prompt: "Fix the button", project, environments, sessions }).environment.id).toBe(
      "local",
    );
  },
);

test.each(["Run tests in the cloud", "Please run this remotely", "Build on a remote machine"])(
  "recognizes destination intent: %s",
  (prompt) => {
    expect(chooseAutoEnvironment({ prompt, environments }).environment.id).toBe("cloud-1");
  },
);

test("a machine-name prefix does not select a different machine", () => {
  expect(chooseAutoEnvironment({ prompt: "Run on gpu-box-extra", environments }).environment.id).toBe("local");
});
