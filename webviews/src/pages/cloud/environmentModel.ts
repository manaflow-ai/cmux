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
  network: { mode: NetworkMode; package_managers: boolean; domains: string[] };
  created_at: string;
  updated_at: string;
  updated_by: string;
  /** The service stores each secret's `hosts` and `header` (cmux-platform#1008). Proposed: the platform does
   *  not answer it yet, so until it does a secret that already has hosts is the only proof (see
   *  `secretRoutesSupported`). */
  secret_routes?: boolean;
  // Codex-style configuration (cmux-platform, in parallel with this editor). Every field is optional: a service
  // without them leaves them out, and the editor shows only what the service answers (`environmentConfig`).
  /** The GitHub repository a machine clones, `owner/name`; null for none. */
  repo?: string | null;
  /** The branch it checks out; null is the repository's default branch. */
  ref?: string | null;
  /** A Bash script run when a machine resumes from the cached snapshot (the setup script runs only on a build). */
  maintenance_script?: string | null;
  /** Text files written to the machine before setup, each by path. */
  files?: EnvironmentFile[];
  /** The base image, by name (`default`: the deployment's Cloud image). */
  image?: string | null;
  /** The images the service allows, when it lists them; otherwise the picker offers the stored one alone. */
  available_images?: EnvironmentImage[];
  /** The last setup or maintenance run, and whether the snapshot is cached or rebuilding (and why). */
  last_run?: SetupRun | null;
  snapshot_status?: SnapshotStatus | null;
  /** Counts every change (cmux-platform#1144). A save sends it as `expected_revision`; a record changed elsewhere
   *  since it was read answers 409 `cloud_environment.revision_conflict`. Absent on an older service. */
  revision?: number;
};
export type NetworkMode = "full" | "limited" | "off";
export type EnvironmentFile = { path: string; content: string };
/** An allowed image: its id, and a name to show when the service gives one. */
export type EnvironmentImage = string | { id: string; name?: string };
export type SetupStepState = "pending" | "running" | "done" | "failed" | "skipped";
export type SetupStep = { id: string; state: SetupStepState; detail?: string | null };
/** One run of the setup or maintenance script, as the Setup output page shows it. */
export type SetupRun = {
  kind: "setup" | "maintenance";
  status: "running" | "succeeded" | "failed";
  steps: SetupStep[];
  /** The last lines of the run's output. */
  log_tail?: string | null;
  error?: { code: string; message: string } | null;
  started_at?: number | null;
  finished_at?: number | null;
};
/** `cached`: new machines boot from the snapshot; `rebuilding`: a build runs, with `reason` saying why. */
export type SnapshotStatus = { state: "cached" | "rebuilding" | "none"; reason?: string | null };
/** The derive endpoint's reply (cmux-platform src/api/Environments.ts DerivedEnvironment); the editor reads its
 *  suggested script and, while the environment answers no `last_run`, its setup's steps and status. */
export type DerivedSetup = {
  setup: { script: string } | null;
  status?: "building" | "ready" | "failed";
  steps?: SetupStep[];
  error?: { code: string; message: string; log_tail?: string | null } | null;
  snapshot?: { id: string } | null;
  refreshing?: boolean;
  /** The last setup or maintenance run's output, kept until the next one ends (cmux-platform#1144). */
  script_output?: {
    kind: "setup" | "maintenance";
    attempt: number;
    exit_code: number;
    log_tail: string;
    finished_at: number;
  } | null;
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
export type EnvironmentPatch = Partial<
  Pick<
    CloudEnvironment,
    "name" | "setup_script" | "env_vars" | "network" | "repo" | "ref" | "maintenance_script" | "files" | "image"
  >
> & {
  set_secrets?: SecretWrite[];
  remove_secrets?: string[];
  /** The revision the edit was made on: the service refuses the save if the record changed since. */
  expected_revision?: number;
};
export type EnvironmentSection =
  | "overview"
  | "repository"
  | "network"
  | "secrets"
  | "script"
  | "maintenance"
  | "variables"
  | "files"
  | "output";
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
  repo: string;
  ref: string;
  maintenance: string;
  files: FileDraft[];
  image: string | null;
};
/** A file row being edited; `id` is the editor's own key, as for variables. */
export type FileDraft = EnvironmentFile & { id?: string };
/** Which of the Codex-style fields this service keeps: each shows only once its reply carries it, so an older
 *  service shows the sheet it had and a save never sends a field it would refuse. */
export type EnvironmentConfig = {
  repository: boolean;
  maintenance: boolean;
  files: boolean;
  image: boolean;
  /** Network Off: offered with the other new fields, or when the stored mode already is Off. */
  off: boolean;
};
export function environmentConfig(environment: CloudEnvironment): EnvironmentConfig {
  const has = (key: keyof CloudEnvironment) => Object.hasOwn(environment, key);
  const configured = has("repo") || has("maintenance_script") || has("files");
  return {
    repository: has("repo"),
    maintenance: has("maintenance_script"),
    files: Array.isArray(environment.files),
    image: has("image") || (environment.available_images?.length ?? 0) > 0,
    off: configured || environment.network.mode === "off",
  };
}
export const imageId = (image: EnvironmentImage) => (typeof image === "string" ? image : image.id);
export const imageName = (image: EnvironmentImage) => (typeof image === "string" ? image : (image.name ?? image.id));
/** The service's file limits (cmux-platform#1144): 20 files, each up to 32 KB, together up to 64 KB. */
export const FILE_BYTES = 32 * 1024;
export const FILES_BYTES = 64 * 1024;
export const FILES_MAX = 20;
const bytes = (text: string) => new TextEncoder().encode(text).byteLength;
/** The images the picker offers: the service's list, else the stored image alone. */
export function imageOptions(environment: CloudEnvironment): EnvironmentImage[] {
  if (environment.available_images?.length) return environment.available_images;
  return environment.image ? [environment.image] : [];
}
const REPO = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/;
/** Whether `text` has a control character (below space, or DEL). */
function hasControl(text: string): boolean {
  for (let at = 0; at < text.length; at++) {
    const code = text.charCodeAt(at);
    if (code < 32 || code === 127) return true;
  }
  return false;
}
// A git ref name, loosely: no spaces, control characters or the characters git refuses, no `..`, and no `/` at
// either end.
const refValid = (ref: string) =>
  ref.length <= 200 &&
  !ref.includes("..") &&
  !ref.startsWith("/") &&
  !ref.endsWith("/") &&
  !/[\s~^:?*[\\]/.test(ref) &&
  !hasControl(ref);
export const repositoryValid = (repo: string, ref: string) =>
  (repo.trim() === "" && ref.trim() === "") || (REPO.test(repo.trim()) && (ref.trim() === "" || refValid(ref.trim())));
/** A path in the repository's checkout, as the service takes it: relative, `/`-separated, no empty, `.` or `..`
 *  part, no backslash or control character, not under `.git`, at most 512 characters. */
export const filePathValid = (path: string) => {
  if (!path || path.length > 512 || path.startsWith("~") || path.includes("\\")) return false;
  if (hasControl(path)) return false;
  const parts = path.split("/");
  return parts.every((part) => part !== "" && part !== "." && part !== "..") && parts[0]!.toLowerCase() !== ".git";
};
export const SETUP_SCRIPT_BYTES = 64 * 1024;
export const scriptFits = (script: string) => new TextEncoder().encode(script).byteLength <= SETUP_SCRIPT_BYTES;
export const fileFits = (content: string) => bytes(content) <= FILE_BYTES && !content.includes("\0");
export const filesFit = (files: readonly EnvironmentFile[]) =>
  files.length <= FILES_MAX && files.reduce((total, file) => total + bytes(file.content), 0) <= FILES_BYTES;

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
    repo: environment.repo ?? "",
    ref: environment.ref ?? "",
    maintenance: environment.maintenance_script ?? "",
    files: (environment.files ?? []).map(({ path, content }) => ({ id: rowId(), path, content })),
    image: environment.image ?? null,
  };
}

/** The first thing that stops Save. `routes` is whether the service keeps where secrets go
 *  (`secretRoutesSupported`): there every secret needs a host, because its value goes only to its hosts
 *  through a vault edge grant and never to the machine. */
export function validateEnvironment(
  draft: EnvironmentDraft,
  { routes = false }: { routes?: boolean } = {},
):
  | "name"
  | "names"
  | "script"
  | "maintenance"
  | "repository"
  | "filePath"
  | "fileSize"
  | "filesSize"
  | "hosts"
  | "hostless"
  | "value"
  | "header"
  | "route"
  | undefined {
  if (!draft.name.trim()) return "name";
  if (draft.script !== null && !scriptFits(draft.script)) return "script";
  if (!scriptFits(draft.maintenance)) return "maintenance";
  if (!repositoryValid(draft.repo, draft.ref)) return "repository";
  const paths = draft.files.map((file) => file.path.trim());
  if (draft.files.some((file) => !filePathValid(file.path.trim())) || new Set(paths).size !== paths.length)
    return "filePath";
  if (draft.files.some((file) => !fileFits(file.content))) return "fileSize";
  if (!filesFit(draft.files)) return "filesSize";
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
  // The Codex-style fields go only to a service that answered them (`environmentConfig`), and only when changed.
  const config = environmentConfig(original);
  if (config.repository) {
    const repo = draft.repo.trim() || null;
    const ref = (repo && draft.ref.trim()) || null;
    if (repo !== (original.repo ?? null)) patch.repo = repo;
    if (ref !== (original.ref ?? null)) patch.ref = ref;
  }
  if (config.maintenance && (draft.maintenance || null) !== (original.maintenance_script ?? null))
    patch.maintenance_script = draft.maintenance || null;
  if (config.files) {
    const files = draft.files.map(({ path, content }) => ({ path: path.trim(), content }));
    if (JSON.stringify(files) !== JSON.stringify(original.files ?? [])) patch.files = files;
  }
  if (config.image && draft.image !== (original.image ?? null)) patch.image = draft.image;
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
  derive(options: { repo: string; ref?: string; environment: string }): Promise<DerivedSetup>;
  /** A new environment (`POST /v1/cloud-environments`); its setup is derived until one is written. */
  create?(environment: { name: string; setup_script: null }): Promise<CloudEnvironment>;
}

/** What the Setup output page shows: the environment's own `last_run` and `snapshot_status` when the service
 *  answers them, else the derive reply (cmux-platform#1144): its last script's output (`script_output`: setup or
 *  maintenance, exit code, log tail), the steps of a setup that runs, and whether the snapshot is ready or being
 *  built. The derive reply says no reason for a rebuild of an existing snapshot, so none is shown then. */
export type SetupOutput = { run?: SetupRun; snapshot?: SnapshotStatus };
export function setupOutput(environment: CloudEnvironment | undefined, derived?: DerivedSetup): SetupOutput {
  const output: SetupOutput = {};
  if (environment?.last_run) output.run = environment.last_run;
  if (environment?.snapshot_status) output.snapshot = environment.snapshot_status;
  if (!derived?.status) return output;
  const building = derived.status === "building" || derived.refreshing === true;
  if (!output.run) {
    const last = derived.script_output;
    if (building && derived.steps?.length) {
      output.run = { kind: "setup", status: "running", steps: derived.steps };
    } else if (last) {
      output.run = {
        kind: last.kind,
        status: last.exit_code === 0 ? "succeeded" : "failed",
        steps: last.kind === "setup" ? (derived.steps ?? []) : [],
        log_tail: last.log_tail,
        error: derived.error ? { code: derived.error.code, message: derived.error.message } : null,
        finished_at: last.finished_at,
      };
    } else if (derived.steps?.length) {
      output.run = {
        kind: "setup",
        status: derived.status === "ready" ? "succeeded" : "failed",
        steps: derived.steps,
        log_tail: derived.error?.log_tail ?? null,
        error: derived.error ? { code: derived.error.code, message: derived.error.message } : null,
      };
    }
  }
  if (!output.snapshot) {
    output.snapshot = building
      ? { state: "rebuilding", reason: derived.snapshot ? null : "first" }
      : derived.snapshot
        ? { state: "cached" }
        : { state: "none" };
  }
  return output;
}

/** A part of the environment a save changes, as the conflict check compares them. */
export type EnvironmentField =
  | "name"
  | "setup_script"
  | "env_vars"
  | "network"
  | "repo"
  | "ref"
  | "maintenance_script"
  | "files"
  | "image"
  | "secrets";
const FIELDS: Exclude<EnvironmentField, "secrets">[] = [
  "name",
  "setup_script",
  "env_vars",
  "network",
  "repo",
  "ref",
  "maintenance_script",
  "files",
  "image",
];
const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
/** The secret names a patch writes or removes. */
const touchedSecrets = (patch: EnvironmentPatch) => [
  ...(patch.set_secrets ?? []).map((entry) => entry.name),
  ...(patch.remove_secrets ?? []),
];

/** The fields the person's edit changed (from `environmentPatch(original, draft)`) that someone else also changed
 *  between `original` and `fresh`: a secret counts when one the person touched was written or removed there. */
export function conflictingFields(
  original: CloudEnvironment,
  fresh: CloudEnvironment,
  patch: EnvironmentPatch,
): EnvironmentField[] {
  const fields: EnvironmentField[] = FIELDS.filter(
    (field) => Object.hasOwn(patch, field) && !same(original[field], fresh[field]),
  );
  const secret = (environment: CloudEnvironment, name: string) =>
    environment.secrets.find((item) => item.name === name);
  if (touchedSecrets(patch).some((name) => !same(secret(original, name), secret(fresh, name)))) fields.push("secrets");
  return fields;
}

/** The person's draft moved onto `fresh`: every field they changed keeps their value, except a conflicting one
 *  when `mine` is false (it takes the newest); every field they did not change takes the newest. Typed secret
 *  values stay with their rows. */
export function rebasedDraft(
  original: CloudEnvironment,
  fresh: CloudEnvironment,
  draft: EnvironmentDraft,
  { mine }: { mine: boolean },
): EnvironmentDraft {
  const patch = environmentPatch(original, draft);
  const conflicts = new Set(conflictingFields(original, fresh, patch));
  const keep = (field: EnvironmentField) => Object.hasOwn(patch, field) && (mine || !conflicts.has(field));
  const next = environmentDraft(fresh);
  const touched = touchedSecrets(patch);
  const secretsKept = touched.length > 0 && (mine || !conflicts.has("secrets"));
  return {
    name: keep("name") ? draft.name : next.name,
    script: keep("setup_script") ? draft.script : next.script,
    variables: keep("env_vars") ? draft.variables : next.variables,
    network: keep("network") ? draft.network : next.network,
    repo: keep("repo") ? draft.repo : next.repo,
    ref: keep("ref") ? draft.ref : next.ref,
    maintenance: keep("maintenance_script") ? draft.maintenance : next.maintenance,
    files: keep("files") ? draft.files : next.files,
    image: keep("image") ? draft.image : next.image,
    secrets: secretsKept
      ? [
          ...next.secrets
            .filter((row) => !patch.remove_secrets?.includes(row.name))
            .map((row) => draft.secrets.find((kept) => kept.name === row.name && touched.includes(row.name)) ?? row),
          ...draft.secrets.filter(
            (row) => touched.includes(row.name) && !next.secrets.some((stored) => stored.name === row.name),
          ),
        ]
      : next.secrets,
  };
}
