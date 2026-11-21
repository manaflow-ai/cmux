// l10n-allow-file: test and gallery fixtures (sample names, scripts and variables), not shipped UI.
// Settings > Cloud > Cloud Environments' host (`cmux.settings.cloud_environment`) as the app answers it:
// the platform's `/v1/cloud-environments` for the signed-in account, which always has a personal Default.
import { ProtocolError } from "../../protocol/errors";
import type { CloudEnvironment, EnvironmentPatch } from "../cloud/environmentModel";
import type { CloudEnvironmentCall } from "./ops";

const stamp = "2026-11-19T10:00:00.000Z";

export const mockDefaultEnvironment: CloudEnvironment = {
  id: "env_0000000000000000000000d1",
  scope: "personal",
  name: "Default",
  is_default: true,
  setup_script: null,
  env_vars: [],
  secrets: [],
  network: { mode: "full", package_managers: true, domains: [] },
  created_at: stamp,
  updated_at: stamp,
  updated_by: "user_mock",
};

export const mockTeamEnvironment: CloudEnvironment = {
  id: "env_0000000000000000000000e2",
  scope: "team",
  name: "web",
  is_default: false,
  setup_script: "cd web && bun install",
  env_vars: [{ name: "NODE_ENV", value: "development" }],
  secrets: [{ name: "OPENAI_API_KEY", updated_at: stamp, hosts: ["api.openai.com"] }],
  network: { mode: "full", package_managers: true, domains: [] },
  created_at: stamp,
  updated_at: stamp,
  updated_by: "user_mock",
  secret_routes: true,
};

/** The account's environments and every call the page sent, in order (tests). */
export class MockCloudEnvironments {
  environments: CloudEnvironment[] = [mockTeamEnvironment, mockDefaultEnvironment];
  calls: CloudEnvironmentCall[] = [];
  /** Cloud off or signed out: every call answers `cloud_disabled`, as the app does. */
  disabled = false;

  run(call: CloudEnvironmentCall): unknown {
    this.calls.push(call);
    if (this.disabled) throw new ProtocolError("cloud_disabled", "cloud_disabled");
    const params = call.params as Record<string, unknown>;
    switch (call.method) {
      case "cloud.environment.list":
        return this.environments;
      case "cloud.environment.get":
        return this.find(String(params.id));
      case "cloud.environment.update": {
        const current = this.find(String(params.id));
        const next = applyPatch(current, params.patch as EnvironmentPatch);
        this.environments = this.environments.map((row) => (row.id === next.id ? next : row));
        return next;
      }
      case "cloud.environment.create": {
        const { name } = params.environment as { name: string };
        const made: CloudEnvironment = {
          ...mockDefaultEnvironment,
          id: `env_${String(this.environments.length + 1).padStart(24, "0")}`,
          name,
          is_default: false,
        };
        this.environments = [...this.environments, made];
        return made;
      }
      case "cloud.environment.derive":
        return { setup: { script: "bun install" } };
    }
  }

  private find(id: string): CloudEnvironment {
    const row = this.environments.find((item) => item.id === id);
    if (!row) throw new ProtocolError("cloud_environment.not_found", "no such environment");
    return row;
  }
}

/** What the platform's PATCH does to the stored environment (secret values are never kept). */
function applyPatch(row: CloudEnvironment, patch: EnvironmentPatch): CloudEnvironment {
  const removed = new Set(patch.remove_secrets ?? []);
  const kept = row.secrets.filter((secret) => !removed.has(secret.name));
  const written = (patch.set_secrets ?? []).map(({ name, hosts, header }) => ({
    name,
    updated_at: stamp,
    ...(hosts ? { hosts } : {}),
    ...(header ? { header } : {}),
  }));
  return {
    ...row,
    ...(patch.name !== undefined ? { name: patch.name } : {}),
    ...(patch.setup_script !== undefined ? { setup_script: patch.setup_script } : {}),
    ...(patch.env_vars !== undefined ? { env_vars: patch.env_vars } : {}),
    ...(patch.network !== undefined ? { network: patch.network } : {}),
    secrets: [...kept.filter((secret) => !written.some((write) => write.name === secret.name)), ...written],
    updated_at: stamp,
  };
}
