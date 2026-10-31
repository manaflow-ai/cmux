import { describe, expect, test } from "bun:test";
import { chooseAutoEnvironment, type AutoEnvironmentChoice } from "../src/agent-session/acpmux/autoEnvironment";

const environments = [
  { id: "local", label: "This Mac", kind: "local" as const },
  { id: "gpu-box", label: "gpu-box", kind: "ssh" as const, connected: true },
  { id: "cloud-1", label: "cloud-1", kind: "cloud" as const, connected: true },
];

/// Where a choice sends the prompt: the Cloud row, or a machine's id.
const where = (choice: AutoEnvironmentChoice) => (choice.to === "cloud" ? "cloud" : choice.environment.id);

describe("new chat Auto environment", () => {
  test("keeps local work local by default", () => {
    expect(where(chooseAutoEnvironment({ prompt: "Fix the button", environments }))).toBe("local");
  });

  test("uses a named ready machine from the prompt", () => {
    expect(where(chooseAutoEnvironment({ prompt: "Run this on gpu-box", environments }))).toBe("gpu-box");
  });

  test("does not forward a local project path to a prompt-selected remote", () => {
    const choice = chooseAutoEnvironment({
      prompt: "Start a cloud build",
      project: "/Users/alice/src/app",
      environments,
    });
    expect(choice).toMatchObject({ to: "machine", environment: { id: "cloud-1" } });
    expect(choice.to === "machine" && choice.cwd).toBeFalsy();
  });

  test("without the Cloud row, a cloud request takes a ready Cloud machine", () => {
    expect(where(chooseAutoEnvironment({ prompt: "Start a cloud build", environments }))).toBe("cloud-1");
  });

  test("does not choose a machine that is unavailable", () => {
    expect(
      where(
        chooseAutoEnvironment({
          prompt: "Run this on gpu-box",
          environments: environments.map((environment) =>
            environment.id === "gpu-box" ? { ...environment, connected: false } : environment,
          ),
        }),
      ),
    ).toBe("local");
  });

  test("explicit local intent wins over remote keywords", () => {
    expect(where(chooseAutoEnvironment({ prompt: "Build the macOS app locally", environments }))).toBe("local");
  });

  test("requires a complete machine-name reference", () => {
    expect(
      where(
        chooseAutoEnvironment({
          prompt: "Improve the developer documentation",
          environments: [...environments, { id: "dev", label: "dev", kind: "ssh", connected: true }],
        }),
      ),
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

const ordinary = [
  "Fix the build error in this repo",
  "Fix the server startup",
  "Update the cloud documentation",
  "Do not run this in the cloud",
  "Don't run this on gpu-box",
  "Never deploy to the cloud",
  "Run tests without using the cloud",
  "Fix the bug mentioning gpu-box",
  "Fix the bug here",
  "Explain what this does locally",
];

test.each(ordinary)("keeps an ordinary or negated instruction on the folder's run location: %s", (prompt) => {
  const project = "/Users/alice/src/app";
  expect(where(chooseAutoEnvironment({ prompt, project, environments }))).toBe("local");
  expect(chooseAutoEnvironment({ prompt, project, folder: "cloud", cloudRow: true, environments })).toEqual({
    to: "cloud",
    reason: "folder",
  });
});

test.each(["Run tests in the cloud", "Please run this remotely", "Build on a remote machine"])(
  "recognizes destination intent: %s",
  (prompt) => {
    expect(where(chooseAutoEnvironment({ prompt, environments }))).toBe("cloud-1");
    // Cloud is the picker's Cloud row when it offers one (cloudRun.ts), not a listed machine.
    expect(chooseAutoEnvironment({ prompt, cloudRow: true, environments })).toEqual({ to: "cloud", reason: "prompt" });
  },
);

test("an explicit request moves the folder's Cloud default: a named machine, or this Mac", () => {
  const cloudFolder = { folder: "cloud" as const, cloudRow: true, environments };
  expect(where(chooseAutoEnvironment({ prompt: "Run the tests on gpu-box", ...cloudFolder }))).toBe("gpu-box");
  expect(chooseAutoEnvironment({ prompt: "Run the tests locally", ...cloudFolder })).toMatchObject({
    to: "local",
    reason: "prompt",
  });
});

test("a Cloud folder default with no Cloud row offered stays on this Mac", () => {
  expect(chooseAutoEnvironment({ prompt: "Fix the button", folder: "cloud", environments })).toMatchObject({
    to: "local",
    reason: "folder",
  });
});

test("a machine-name prefix does not select a different machine", () => {
  expect(where(chooseAutoEnvironment({ prompt: "Run on gpu-box-extra", environments }))).toBe("local");
});

test("an incidental local is no destination: the named machine or cloud ask wins, on either folder default", () => {
  for (const folder of ["local", "cloud"] as const) {
    const options = { folder, cloudRow: true, environments };
    expect(
      where(chooseAutoEnvironment({ prompt: "Run the tests on gpu-box using the local dataset", ...options })),
    ).toBe("gpu-box");
    expect(
      where(chooseAutoEnvironment({ prompt: "Run the tests in the cloud with the local config", ...options })),
    ).toBe("cloud");
  }
});

test("a machine name may end the sentence, but not be the start of a longer host name", () => {
  expect(where(chooseAutoEnvironment({ prompt: "Run the tests on gpu-box.", environments }))).toBe("gpu-box");
  expect(where(chooseAutoEnvironment({ prompt: "Run the tests on gpu-box. Then fix them", environments }))).toBe(
    "gpu-box",
  );
  expect(where(chooseAutoEnvironment({ prompt: "Run the tests on gpu-box.example.com", environments }))).toBe("local");
});

test("a possessive names the destination too: my machine, my remote server, our VM", () => {
  expect(where(chooseAutoEnvironment({ prompt: "Run the tests on my gpu-box", environments }))).toBe("gpu-box");
  for (const prompt of ["Run this on my remote server", "Build on our VM"])
    expect(chooseAutoEnvironment({ prompt, cloudRow: true, environments })).toEqual({ to: "cloud", reason: "prompt" });
});
