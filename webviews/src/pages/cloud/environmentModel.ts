/** The platform's cloud-environment schema; secret values appear only in PATCH drafts. */
export type EnvironmentVariable = { name: string; value: string };
export type CloudEnvironment = {
  id: string;
  scope: "personal" | "team";
  name: string;
  is_default: boolean;
  setup_script: string | null;
  env_vars: EnvironmentVariable[];
  secrets: EnvironmentSecret[];
  network: { mode: "full" | "limited"; package_managers: boolean; domains: string[] };
  created_at: string;
  updated_at: string;
  updated_by: string;
  /** The service stores each secret's `hosts` and `header` (cmux-platform#1008). Proposed: the platform does
   *  not answer it yet, so until it does a secret that already has hosts is the only proof (see
   *  `secretRoutesSupported`). */
  secret_routes?: boolean;
};
/** The header a secret with `hosts` goes in; `format` holds `{value}`, which the edge replaces with the value. */
export type SecretHeader = { name: string; format: string };
/** A stored secret as GET answers it: never a value. `hosts` and `header` are its delivery targets (the
 *  vault's edge grants). Every secret needs a host: its value never reaches the machine, so one stored
 *  without hosts (from before) loads as invalid until it gets one. Older platforms omit both. */
export type EnvironmentSecret = { name: string; updated_at: string; hosts?: string[]; header?: SecretHeader };
/** A `set_secrets` entry. It always states where the secret goes in full: no `header` is the default, never
 *  "unchanged", and `hosts` is left out only on a service that does not keep routes (the editor refuses a
 *  secret without hosts everywhere else). Only `value` may be left out, which keeps an existing secret's
 *  sealed value and changes where it goes. */
export type SecretWrite = { name: string; value?: string; hosts?: string[]; header?: SecretHeader };
/** A variable row being edited. `id` is the editor's own key for the row (`rowId`), so per-row state stays with
 *  its row when a row above is removed; it never goes to the platform (`environmentPatch` leaves it out). */
export type VariableDraft = EnvironmentVariable & { id?: string };
/** A secret row being edited. `hosts` is the field's text as typed; `header` absent means the default. */
export type SecretDraft = VariableDraft & { hosts?: string; header?: SecretHeader };
export type EnvironmentPatch = Partial<Pick<CloudEnvironment, "name" | "setup_script" | "env_vars" | "network">> & {
  set_secrets?: SecretWrite[];
  remove_secrets?: string[];
};
export type EnvironmentSection = "overview" | "network" | "secrets" | "script" | "variables";
/** `create`: make a new environment by that name first (the composer's New environment…), then edit
 *  it; `onCreated` hears it once it exists. */
export type EnvironmentOpen = {
  environmentId?: string;
  repo?: string;
  ref?: string;
  section?: EnvironmentSection;
  create?: { name: string };
  onCreated?(environment: CloudEnvironment): void;
};
export type EnvironmentDraft = {
  name: string;
  script: string | null;
  variables: VariableDraft[];
  secrets: SecretDraft[];
  network: CloudEnvironment["network"];
};
export const SETUP_SCRIPT_BYTES = 64 * 1024;
export const scriptFits = (script: string) => new TextEncoder().encode(script).byteLength <= SETUP_SCRIPT_BYTES;

export const SECRET_HOSTS_MAX = 8;
export const DEFAULT_SECRET_HEADER: SecretHeader = { name: "authorization", format: "Bearer {value}" };
// An exact host name: lowercase labels with at least one dot; no scheme, port, path or wildcard.
const HOST = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;
// The platform's rules (cmux-platform#1008, src/api/CloudEnvironments.ts): a lowercase header name (an RFC 9110
// token; the editor folds case before checking), a format of at most 256 characters holding {value}, and never
// a header that frames or routes the request itself.
const HEADER_NAME = /^[a-z0-9!#$%&'*+.^_`|~-]{1,64}$/;
export const RESERVED_SECRET_HEADERS = new Set([
  "host",
  "content-length",
  "transfer-encoding",
  "connection",
  "upgrade",
]);

/** The host field's names: split on commas and spaces, lowercased (host names ignore case), deduplicated. */
export function secretHosts(text: string | undefined): string[] {
  return [
    ...new Set(
      (text ?? "")
        .split(/[\s,]+/)
        .map((host) => host.toLowerCase())
        .filter(Boolean),
    ),
  ];
}
export function hostsValid(text: string | undefined): boolean {
  const hosts = secretHosts(text);
  return hosts.length <= SECRET_HOSTS_MAX && hosts.every((host) => HOST.test(host));
}
/** Why a header can't be used: `header` for a bad name or format, `route` for a header the request itself needs. */
export function headerIssue(header: SecretHeader | undefined): "header" | "route" | undefined {
  if (!header) return;
  const name = header.name.toLowerCase();
  if (!HEADER_NAME.test(name)) return "header";
  if (RESERVED_SECRET_HEADERS.has(name)) return "route";
  if (header.format.length > 256 || !header.format.includes("{value}") || !headerText(header.format)) return "header";
}
/** A value or format that goes into a request header: printable ASCII, spaces and tabs (no line break, control
 *  or non-ASCII character), as the platform requires (`cloud_environment.invalid_value`). */
export const headerText = (text: string) => /^[\x20-\x7e\t]*$/.test(text);
/** A secret stored without hosts (from before every secret needed one) getting its first hosts: the platform
 *  needs its value again, because a value-less entry only moves a secret that already has hosts. */
export function secretNeedsValue(row: SecretDraft, stored: EnvironmentSecret | undefined): boolean {
  return !row.value && stored !== undefined && !stored.hosts?.length && secretHosts(row.hosts).length > 0;
}
/** Where a secret row goes, as the platform stores it. A row without hosts states nothing: the editor refuses
 *  it before Save wherever the service keeps routes (`validateEnvironment`). */
export function secretDelivery(row: Pick<SecretDraft, "hosts" | "header">): Pick<SecretWrite, "hosts" | "header"> {
  const hosts = secretHosts(row.hosts);
  if (!hosts.length) return {};
  const header = row.header && { name: row.header.name.toLowerCase(), format: row.header.format };
  const custom =
    header && (header.name !== DEFAULT_SECRET_HEADER.name || header.format !== DEFAULT_SECRET_HEADER.format);
  return custom ? { hosts, header } : { hosts };
}
/** True when an existing secret's hosts or header differ from what the platform has: saving sends a
 *  `set_secrets` entry without a value, which keeps the sealed value and changes only where it goes. */
export function secretDeliveryChanged(row: SecretDraft, stored: EnvironmentSecret): boolean {
  return (
    JSON.stringify(secretDelivery(row)) !==
    JSON.stringify(secretDelivery({ hosts: stored.hosts?.join(", "), header: stored.header }))
  );
}

/** The environment as the editor keeps it: each secret's name, time and delivery only, so a value a server
 *  or bridge sends by mistake is dropped on arrival, never held or drawn. */
export function storedEnvironment(environment: CloudEnvironment): CloudEnvironment {
  return {
    ...environment,
    secrets: environment.secrets.map(({ name, updated_at, hosts, header }) => ({
      name,
      updated_at,
      ...(hosts ? { hosts: [...hosts] } : {}),
      ...(header ? { header: { name: header.name, format: header.format } } : {}),
    })),
  };
}

/** Whether this Cloud service keeps where a secret is sent. A service without it drops `hosts` and `header` and
 *  saves the value as a plain variable, so the editor offers delivery only on proof: the reply declares
 *  `secret_routes`, or a stored secret already has hosts. An empty field proves nothing. */
export function secretRoutesSupported(environment: CloudEnvironment): boolean {
  return environment.secret_routes === true || environment.secrets.some((secret) => (secret.hosts?.length ?? 0) > 0);
}
const routeKey = (route: Pick<SecretWrite, "hosts" | "header">) =>
  JSON.stringify(secretDelivery({ hosts: [...(route.hosts ?? [])].sort().join(", "), header: route.header }));
/** The secrets a save sent to hosts that the reply did not keep there: each one is now a plain variable. */
export function droppedRoutes(patch: EnvironmentPatch, reply: CloudEnvironment): string[] {
  return (patch.set_secrets ?? [])
    .filter((entry) => entry.hosts?.length)
    .filter((entry) => {
      const kept = reply.secrets.find((secret) => secret.name === entry.name);
      return !kept || routeKey(kept) !== routeKey(entry);
    })
    .map((entry) => entry.name);
}

let rows = 0;
/** A new row's id: unique in this page, client-side only. */
export const rowId = () => `row-${++rows}`;
/** Gives every row an id. A row without one takes the id of the row at its place in `previous` (an edit that
 *  restates the list keeps each row's state), or a new one. */
export function withRowIds<Row extends { id?: string }>(next: Row[], previous: readonly { id?: string }[] = []): Row[] {
  const taken = new Set(next.map((row) => row.id).filter(Boolean));
  return next.map((row, at) => {
    if (row.id) return row;
    const kept = previous[at]?.id;
    return { ...row, id: kept && !taken.has(kept) ? kept : rowId() };
  });
}

export function environmentDraft(environment: CloudEnvironment): EnvironmentDraft {
  return {
    name: environment.name,
    script: environment.setup_script,
    variables: environment.env_vars.map(({ name, value }) => ({ id: rowId(), name, value })),
    // Only names and delivery targets: a value is never read from the server, even one sent by mistake.
    secrets: environment.secrets.map(({ name, hosts, header }) => ({
      id: rowId(),
      name,
      value: "",
      ...(hosts?.length ? { hosts: hosts.join(", ") } : {}),
      ...(hosts?.length && header ? { header: { name: header.name, format: header.format } } : {}),
    })),
    network: { ...environment.network, domains: [...environment.network.domains] },
  };
}

/** The first thing that stops Save. `routes` is whether the service keeps where secrets go
 *  (`secretRoutesSupported`): there every secret needs a host, because its value goes only to its hosts
 *  through a vault edge grant and never to the machine. */
export function validateEnvironment(
  draft: EnvironmentDraft,
  { routes = false }: { routes?: boolean } = {},
): "name" | "names" | "script" | "hosts" | "hostless" | "value" | "header" | "route" | undefined {
  if (!draft.name.trim()) return "name";
  if (draft.script !== null && !scriptFits(draft.script)) return "script";
  for (const rows of [draft.variables, draft.secrets]) {
    const names = rows.map((row) => row.name);
    if (new Set(names).size !== names.length || names.some((name) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)))
      return "names";
  }
  if (draft.secrets.some((row) => !hostsValid(row.hosts))) return "hosts";
  if (routes && draft.secrets.some((row) => !secretHosts(row.hosts).length)) return "hostless";
  for (const row of draft.secrets) {
    if (!secretHosts(row.hosts).length) continue;
    if (!headerText(row.value)) return "value";
    const issue = headerIssue(row.header);
    if (issue) return issue;
  }
}

/** Send only changed fields, so viewing an auto-derived script does not pin it as a custom script. */
export function environmentPatch(original: CloudEnvironment, draft: EnvironmentDraft): EnvironmentPatch {
  const patch: EnvironmentPatch = {};
  if (!original.is_default && draft.name.trim() !== original.name) patch.name = draft.name.trim();
  if (draft.script !== original.setup_script) patch.setup_script = draft.script;
  // Rows' ids are the editor's own: never compared, never sent.
  const variables = draft.variables.map(({ name, value }) => ({ name, value }));
  if (JSON.stringify(variables) !== JSON.stringify(original.env_vars)) patch.env_vars = variables;
  const network = {
    ...draft.network,
    domains: [...new Set(draft.network.domains.map((domain) => domain.trim()).filter(Boolean))],
  };
  if (JSON.stringify(network) !== JSON.stringify(original.network)) patch.network = network;
  // An entry only for a secret whose value, hosts or header changed; each states its delivery in full.
  const set = draft.secrets
    .filter((row) => {
      if (row.value !== "") return true;
      const stored = original.secrets.find((secret) => secret.name === row.name);
      return stored !== undefined && secretDeliveryChanged(row, stored);
    })
    .map((row): SecretWrite => ({
      name: row.name,
      ...(row.value ? { value: row.value } : {}),
      ...secretDelivery(row),
    }));
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
  /** A new environment (`POST /v1/cloud-environments`); its setup is derived until one is written. */
  create?(environment: { name: string; setup_script: null }): Promise<CloudEnvironment>;
}
