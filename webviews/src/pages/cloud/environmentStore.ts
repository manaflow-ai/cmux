import {
  environmentDraft,
  droppedRoutes,
  environmentPatch,
  scriptFits,
  secretNeedsValue,
  secretRoutesSupported,
  SETUP_SCRIPT_BYTES,
  storedEnvironment,
  validateEnvironment,
  withRowIds,
  conflictingFields,
  rebasedDraft,
  type CloudEnvironment,
  type DerivedSetup,
  type EnvironmentField,
  type EnvironmentClient,
  type EnvironmentDraft,
  type EnvironmentOpen,
  type EnvironmentSection,
} from "./environmentModel";

export type EnvironmentState = {
  open: boolean;
  section: EnvironmentSection;
  loading: boolean;
  saving: boolean;
  original?: CloudEnvironment;
  draft?: EnvironmentDraft;
  derivedScript?: string;
  /** The last derive reply, for the Setup output page while the environment answers no `last_run`. */
  derived?: DerivedSetup;
  deriving?: boolean;
  /** The save met a record changed elsewhere (409 `cloud_environment.revision_conflict`) and some of the fields
   *  the person changed were changed there too: the newest record, and those fields. Their edits stay in `draft`
   *  until they pick Keep my edits or Use the newest. */
  conflict?: { fresh: CloudEnvironment; fields: EnvironmentField[] };
  deriveFailed?: boolean;
  error?:
    | "load"
    | "save"
    | "missing"
    | "name"
    | "names"
    | "script"
    | "maintenance"
    | "repository"
    | "filePath"
    | "fileSize"
    | "filesSize"
    | "file"
    | "copy"
    | "secret"
    | "retype"
    | "hosts"
    | "hostless"
    | "value"
    | "header"
    | "route"
    | "dropped"
    | "conflict"
    | "vaultDown"
    | "vaultHost"
    | "vaultText"
    | "vaultUnreadable"
    | "vaultRefused";
};

/** The platform's secret refusals (cmux-platform#1008), shown as the same sentence the editor's own check shows.
 *  `secret_value_required`: a value-less entry for a secret removed elsewhere since the sheet opened.
 *  `invalid_secret_route`: a header the request itself needs, a header without hosts, or a host given twice.
 *  `invalid_value`: a value or header format with a line break, control or non-ASCII character. */
const refusals: Record<string, EnvironmentState["error"]> = {
  "cloud_environment.secret_value_required": "secret",
  "cloud_environment.invalid_secret_route": "route",
  "cloud_environment.invalid_value": "value",
  // A file the service refuses (cmux-platform#1144): a path or size its checks stop that the editor's did not.
  "cloud_environment.invalid_file": "filePath",
  // A second conflict after the edits were moved onto the newest record (the first is handled by `rebase`).
  "cloud_environment.revision_conflict": "conflict",
  // Saving a secret sent to hosts writes it to the secret store; its refusals (cmux-platform#1046). Another
  // vault.* code (one only a machine's start gives) stays the generic save error.
  "vault.unavailable": "vaultDown",
  "vault.unreachable": "vaultDown",
  "vault.upstream_failed": "vaultDown",
  "vault.not_configured": "vaultDown",
  "vault.pin_public_suffix": "vaultHost",
  "vault.secret_not_ascii": "vaultText",
  "vault.secret_unreadable": "vaultUnreadable",
  "vault.grant_refused": "vaultRefused",
  "vault.request_rejected": "vaultRefused",
};

/** The environments the editor last read, by id (and the personal Default under `default`), with their last
 *  derive reply: a reopened sheet draws them at once and refreshes in place, with no loading line over data it
 *  has. Secret values are never in it (`storedEnvironment` runs first). Bounded: the oldest goes first. */
export class EnvironmentCache {
  private environments = new Map<string, CloudEnvironment>();
  private derived = new Map<string, DerivedSetup>();
  constructor(private limit = 32) {}
  get = (key: string) => this.environments.get(key);
  derivedFor = (id: string) => this.derived.get(id);
  put(environment: CloudEnvironment, ...keys: string[]) {
    for (const key of [environment.id, ...keys]) this.keep(this.environments, key, environment);
  }
  putDerived(id: string, derived: DerivedSetup) {
    this.keep(this.derived, id, derived);
  }
  private keep<T>(map: Map<string, T>, key: string, value: T) {
    map.delete(key);
    map.set(key, value);
    while (map.size > this.limit) map.delete(map.keys().next().value!);
  }
}
/** The cache every editor on this page shares (CloudEnvironmentEditorContent). */
export const sharedEnvironmentCache = new EnvironmentCache();

/** A fresh draft for `environment` that keeps `previous`'s row ids by place, so a refresh in place keeps each
 *  row's own state (an open header). */
function refreshedDraft(environment: CloudEnvironment, previous: EnvironmentDraft | undefined): EnvironmentDraft {
  const draft = environmentDraft(environment);
  if (!previous) return draft;
  const unkeyed = <Row extends { id?: string }>(rows: Row[]): Row[] => rows.map((row) => ({ ...row, id: undefined }));
  return {
    ...draft,
    variables: withRowIds(unkeyed(draft.variables), previous.variables),
    secrets: withRowIds(unkeyed(draft.secrets), previous.secrets),
    files: withRowIds(unkeyed(draft.files), previous.files),
  };
}

/** One draft for every entry point; stale reads never resurrect a closed or different editor. */
export class EnvironmentStore {
  private state: EnvironmentState = { open: false, section: "overview", loading: false, saving: false };
  private listeners = new Set<() => void>();
  private generation = 0;
  private fileGeneration = 0;
  private draftRevision = 0;
  private options: EnvironmentOpen = {};
  constructor(
    private client: EnvironmentClient,
    private cache?: EnvironmentCache,
  ) {}
  getSnapshot = () => this.state;
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  private set(patch: Partial<EnvironmentState>) {
    // A secret value a server sends by mistake is dropped here, whichever read brought it.
    if (patch.original) patch = { ...patch, original: storedEnvironment(patch.original) };
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
  async open(options: EnvironmentOpen = {}) {
    if (this.state.saving) return;
    this.options = options;
    const generation = ++this.generation;
    // Drawn from the cache at once when this environment was read before; the read below refreshes it in place.
    const key = options.environmentId ?? "default";
    const cached = options.create ? undefined : this.cache?.get(key);
    const derived = cached && this.cache?.derivedFor(cached.id);
    this.state = {
      open: true,
      section: options.section ?? "overview",
      loading: !cached,
      saving: false,
      ...(cached ? { original: cached, draft: environmentDraft(cached) } : {}),
      ...(derived ? { derived, ...(derived.setup ? { derivedScript: derived.setup.script } : {}) } : {}),
    };
    const revision = this.draftRevision;
    this.set({});
    try {
      const created =
        options.create && this.client.create
          ? await this.client.create({ name: options.create.name, setup_script: null })
          : undefined;
      if (created) {
        // Made once: a retry or a later open edits it, never makes another.
        const { create: _made, ...rest } = options;
        this.options = { ...rest, environmentId: created.id };
        options.onCreated?.(created);
      }
      const environment =
        created ??
        (options.environmentId
          ? await this.client.get(options.environmentId)
          : (await this.client.list()).find((item) => item.scope === "personal" && item.is_default));
      if (generation !== this.generation) return;
      if (!environment) return this.set({ loading: false, error: "missing" });
      const stored = storedEnvironment(environment);
      this.cache?.put(stored, ...(options.environmentId || created ? [] : ["default"]));
      if (!cached) {
        this.set({ original: stored, draft: environmentDraft(stored), loading: false });
      } else if (JSON.stringify(stored) !== JSON.stringify(this.state.original) && !this.state.saving) {
        // Refreshed in place. Edited since it opened: the draft and what Save compares it with stay as the
        // person saw them (a save sends only their changes); the read-only run and snapshot state still update.
        if (this.draftRevision !== revision)
          this.set({
            original: { ...this.state.original!, last_run: stored.last_run, snapshot_status: stored.snapshot_status },
          });
        else this.set({ original: stored, draft: refreshedDraft(stored, this.state.draft) });
      }
      if (environment.setup_script === null && options.repo) void this.derive();
    } catch {
      // A failed refresh over cached data keeps the data: the person can still read and edit it.
      if (generation === this.generation && !cached) this.set({ loading: false, error: "load" });
    }
  }
  retry = () => this.open(this.options);
  close = () => {
    if (this.state.saving) return;
    ++this.generation;
    // In particular, never retain write-only secret values across openings.
    this.state = { open: false, section: "overview", loading: false, saving: false };
    this.set({});
  };
  section = (section: EnvironmentSection) => this.set({ section });
  edit = (patch: Partial<EnvironmentDraft>) => {
    const { draft } = this.state;
    if (!draft || this.state.saving) return;
    ++this.draftRevision;
    if (patch.secrets) patch = { ...patch, secrets: withRowIds(patch.secrets, draft.secrets) };
    if (patch.variables) patch = { ...patch, variables: withRowIds(patch.variables, draft.variables) };
    if (patch.files) patch = { ...patch, files: withRowIds(patch.files, draft.files) };
    this.set({ draft: { ...draft, ...patch }, error: undefined });
  };
  error = (error: EnvironmentState["error"]) => this.set({ error });
  async derive() {
    const { original } = this.state;
    if (!original || !this.options.repo || this.state.deriving) return;
    const generation = this.generation;
    this.set({ deriving: true, deriveFailed: false });
    try {
      const result = await this.client.derive({
        repo: this.options.repo,
        ref: this.options.ref,
        environment: original.id,
      });
      if (generation !== this.generation) return;
      // No setup yet (the first one still runs): nothing to suggest, and not a failure.
      const script = result.setup?.script;
      if (script !== undefined && !scriptFits(script)) throw new Error("script size");
      this.cache?.putDerived(original.id, result);
      this.set({ ...(script !== undefined ? { derivedScript: script } : {}), derived: result, deriving: false });
    } catch {
      if (generation === this.generation) this.set({ deriving: false, deriveFailed: true });
    }
  }
  /** Reads a chosen file into the setup script, or into the maintenance script (`target`). */
  async importScript(file: Pick<File, "size" | "text">, target: "script" | "maintenance" = "script") {
    const fileGeneration = ++this.fileGeneration;
    if (file.size > SETUP_SCRIPT_BYTES) return this.error(target);
    const generation = this.generation;
    const revision = this.draftRevision;
    try {
      const script = await file.text();
      if (generation !== this.generation || fileGeneration !== this.fileGeneration || revision !== this.draftRevision)
        return;
      if (!scriptFits(script)) return this.error(target);
      this.edit(target === "script" ? { script } : { maintenance: script });
    } catch {
      if (generation === this.generation && fileGeneration === this.fileGeneration && revision === this.draftRevision)
        this.error("file");
    }
  }
  /** `rebased`: this save follows a conflict already moved onto the newest record, so another conflict stops. */
  async save(rebased = false) {
    const { original, draft, saving } = this.state;
    if (!original || !draft || saving) return;
    const invalid = validateEnvironment(draft, { routes: secretRoutesSupported(original) });
    if (invalid) return this.error(invalid);
    if (draft.secrets.some((row) => !row.value && !original.secrets.some((secret) => secret.name === row.name)))
      return this.error("secret");
    if (
      draft.secrets.some((row) =>
        secretNeedsValue(
          row,
          original.secrets.find((secret) => secret.name === row.name),
        ),
      )
    )
      return this.error("retype");
    const patch = environmentPatch(original, draft);
    if (!Object.keys(patch).length) return this.close();
    // On a service that counts revisions, the save is refused if the record changed since it was read, so a save
    // elsewhere is never undone by these whole lists (variables, files). An older service: as before.
    if (original.revision !== undefined) patch.expected_revision = original.revision;
    this.set({ saving: true, error: undefined, conflict: undefined });
    try {
      const reply = await this.client.update(original.id, patch);
      if (droppedRoutes(patch, reply).length) {
        // The service saved the value but not where it goes: it is a plain variable on the machine now. Keep
        // the sheet open on what is stored, so the person sees it and can remove it; never report success.
        // No automatic removal: a second write to a service that just misread the first is no safer.
        return this.set({ saving: false, original: reply, draft: environmentDraft(reply), error: "dropped" });
      }
      this.cache?.put(
        storedEnvironment(reply),
        ...(original.is_default && original.scope === "personal" ? ["default"] : []),
      );
      this.set({ saving: false });
      this.close();
    } catch (error) {
      const code = error instanceof Object && "code" in error ? error.code : undefined;
      if (code === "cloud_environment.revision_conflict" && !rebased) return this.rebase();
      if (code === "cloud_environment.revision_conflict") return this.rebase(false);
      this.set({
        saving: false,
        error: (typeof code === "string" && Object.hasOwn(refusals, code) && refusals[code]) || "save",
      });
    }
  }
  /** A save refused because the record changed elsewhere: read the newest. Where the person's changes and the
   *  other ones touch different fields, theirs are moved onto it and saved again (once, `retry`); where they
   *  overlap, the sheet shows what changed elsewhere and keeps every edit until the person picks. */
  private async rebase(retry = true) {
    const { original, draft } = this.state;
    if (!original || !draft) return;
    const generation = this.generation;
    let fresh: CloudEnvironment;
    try {
      fresh = storedEnvironment(await this.client.get(original.id));
    } catch {
      if (generation === this.generation) this.set({ saving: false, error: "save" });
      return;
    }
    if (generation !== this.generation) return;
    const fields = conflictingFields(original, fresh, environmentPatch(original, draft));
    if (fields.length) return this.set({ saving: false, error: "conflict", conflict: { fresh, fields } });
    this.cache?.put(fresh);
    this.set({ saving: false, original: fresh, draft: rebasedDraft(original, fresh, draft, { mine: true }) });
    if (retry) return this.save(true);
  }
  /** The person's answer to a conflict: keep their edits over the newest record (Save then sends them on its
   *  revision), or take the newest for the overlapping fields and keep the rest of their edits. */
  resolveConflict = (mine: boolean) => {
    const { original, draft, conflict } = this.state;
    if (!original || !draft || !conflict || this.state.saving) return;
    ++this.draftRevision;
    this.set({
      original: conflict.fresh,
      draft: rebasedDraft(original, conflict.fresh, draft, { mine }),
      conflict: undefined,
      error: undefined,
    });
  };
}
