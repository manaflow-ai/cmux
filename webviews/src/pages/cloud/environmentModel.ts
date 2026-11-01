/** The platform's cloud-environment schema; secret values appear only in PATCH drafts. */
export type EnvironmentVariable = { name: string; value: string };
export type CloudEnvironment = {
  id: string;
  scope: "personal" | "team";
  name: string;
  is_default: boolean;
  setup_script: string | null;
  env_vars: EnvironmentVariable[];
  secrets: { name: string; updated_at: string }[];
  network: { mode: "full" | "limited"; package_managers: boolean; domains: string[] };
  created_at: string;
  updated_at: string;
  updated_by: string;
};
export type EnvironmentPatch = Partial<Pick<CloudEnvironment, "name" | "setup_script" | "env_vars" | "network">> & {
  set_secrets?: EnvironmentVariable[];
  remove_secrets?: string[];
};
export type EnvironmentSection = "overview" | "network" | "secrets" | "script" | "variables";
export type EnvironmentOpen = { environmentId?: string; repo?: string; ref?: string; section?: EnvironmentSection };
export type EnvironmentDraft = {
  name: string;
  script: string | null;
  variables: EnvironmentVariable[];
  secrets: EnvironmentVariable[];
  network: CloudEnvironment["network"];
};
export const SETUP_SCRIPT_BYTES = 64 * 1024;
export const scriptFits = (script: string) => new TextEncoder().encode(script).byteLength <= SETUP_SCRIPT_BYTES;

export function environmentDraft(environment: CloudEnvironment): EnvironmentDraft {
  return {
    name: environment.name,
    script: environment.setup_script,
    variables: environment.env_vars.map((row) => ({ ...row })),
    secrets: environment.secrets.map(({ name }) => ({ name, value: "" })),
    network: { ...environment.network, domains: [...environment.network.domains] },
  };
}

export function validateEnvironment(draft: EnvironmentDraft): "name" | "names" | "script" | undefined {
  if (!draft.name.trim()) return "name";
  if (draft.script !== null && !scriptFits(draft.script)) return "script";
  for (const rows of [draft.variables, draft.secrets]) {
    const names = rows.map((row) => row.name);
    if (new Set(names).size !== names.length || names.some((name) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)))
      return "names";
  }
}

/** Send only changed fields, so viewing an auto-derived script does not pin it as a custom script. */
export function environmentPatch(original: CloudEnvironment, draft: EnvironmentDraft): EnvironmentPatch {
  const patch: EnvironmentPatch = {};
  if (!original.is_default && draft.name.trim() !== original.name) patch.name = draft.name.trim();
  if (draft.script !== original.setup_script) patch.setup_script = draft.script;
  if (JSON.stringify(draft.variables) !== JSON.stringify(original.env_vars)) patch.env_vars = draft.variables;
  const network = {
    ...draft.network,
    domains: [...new Set(draft.network.domains.map((domain) => domain.trim()).filter(Boolean))],
  };
  if (JSON.stringify(network) !== JSON.stringify(original.network)) patch.network = network;
  const set = draft.secrets.filter((row) => row.value !== "");
  const remove = original.secrets.filter((row) => !draft.secrets.some((secret) => secret.name === row.name));
  if (set.length) patch.set_secrets = set;
  if (remove.length) patch.remove_secrets = remove.map((row) => row.name);
  return patch;
}

export interface EnvironmentClient {
  list(): Promise<CloudEnvironment[]>;
  get(id: string): Promise<CloudEnvironment>;
  update(id: string, patch: EnvironmentPatch): Promise<CloudEnvironment>;
  derive(options: { repo: string; ref?: string; environment: string }): Promise<{ setup: { script: string } }>;
}
