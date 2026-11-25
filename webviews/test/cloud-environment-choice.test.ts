// Cloud's environment model (cloudEnvironmentChoice.ts). The composer no longer has an Environment
// chip (issue #51731: the image a new Cloud chat boots is Settings > Cloud's Default image); what a
// Cloud start names and which Default Auto runs in stay as they were.
import { expect, test } from "bun:test";

const env = (id: string, name: string, scope: "personal" | "team", isDefault: boolean) => ({
  id,
  scope,
  name,
  is_default: isDefault,
  setup_script: null,
  env_vars: [],
  secrets: [],
  network: { mode: "full", package_managers: true, domains: [] },
  created_at: "1",
  updated_at: "1",
  updated_by: "u",
});
const environments = [env("env_default", "Default", "personal", true), env("env_gpu", "GPU training", "personal", false)];

test("a Cloud start names its own environment, else the pick; Auto names none", async () => {
  const choice = await import("../src/agent-session/acpmux/cloudEnvironmentChoice");
  const { setComposerSettings, DEFAULT_COMPOSER } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings(DEFAULT_COMPOSER);
  expect(choice.cloudStartEnvironment(undefined, choice.AUTO_ENVIRONMENT)).toBeUndefined();
  expect(choice.cloudStartEnvironment(undefined, "env_gpu")).toBe("env_gpu");
  expect(choice.cloudStartEnvironment("env_web", "env_gpu")).toBe("env_web");
  // The flag off sends exactly what it sent before environments existed.
  setComposerSettings({ cloudEnvironments: false });
  expect(choice.cloudStartEnvironment(undefined, "env_gpu")).toBeUndefined();
  setComposerSettings(DEFAULT_COMPOSER);
});

// Leo, 2026-11-22 (ask c-922dfe5e36): a teammate's Auto runs in the team's Default, as the platform
// boots a team chat with no environment.
test("Auto in a team's context is the team's Default; personal Default otherwise", async () => {
  const choice = await import("../src/agent-session/acpmux/cloudEnvironmentChoice");
  const teamDefault = env("env_team_default", "Default", "team", true);
  const teamOther = env("env_team_web", "web", "team", false);
  for (const listed of [
    [...environments, teamDefault, teamOther],
    [teamDefault, ...environments],
  ]) {
    expect(choice.autoEnvironment(listed as never)).toEqual({ id: "env_team_default", name: "Default" });
    expect(choice.autoEditEnvironment(listed as never)).toBe("env_team_default");
  }
  expect(choice.autoEnvironment([...environments, teamOther] as never)).toEqual({ id: "env_default", name: "Default" });
  expect(choice.autoEditEnvironment([...environments, teamOther] as never)).toBeUndefined();
  expect(choice.autoEnvironment(environments as never)).toEqual({ id: "env_default", name: "Default" });
});
