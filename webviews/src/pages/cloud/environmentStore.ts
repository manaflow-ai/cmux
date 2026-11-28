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
  type CloudEnvironment,
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
  deriving?: boolean;
  deriveFailed?: boolean;
  error?:
    | "load"
    | "save"
    | "missing"
    | "name"
    | "names"
    | "script"
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

/** One draft for every entry point; stale reads never resurrect a closed or different editor. */
export class EnvironmentStore {
  private state: EnvironmentState = { open: false, section: "overview", loading: false, saving: false };
  private listeners = new Set<() => void>();
  private generation = 0;
  private fileGeneration = 0;
  private draftRevision = 0;
  private options: EnvironmentOpen = {};
  constructor(private client: EnvironmentClient) {}
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
    this.state = { open: true, section: options.section ?? "overview", loading: true, saving: false };
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
      this.set({ original: environment, draft: environmentDraft(environment), loading: false });
      if (environment.setup_script === null && options.repo) void this.derive();
    } catch {
      if (generation === this.generation) this.set({ loading: false, error: "load" });
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
      if (!scriptFits(result.setup.script)) throw new Error("script size");
      this.set({ derivedScript: result.setup.script, deriving: false });
    } catch {
      if (generation === this.generation) this.set({ deriving: false, deriveFailed: true });
    }
  }
  async importScript(file: Pick<File, "size" | "text">) {
    const fileGeneration = ++this.fileGeneration;
    if (file.size > SETUP_SCRIPT_BYTES) return this.error("script");
    const generation = this.generation;
    const revision = this.draftRevision;
    try {
      const script = await file.text();
      if (generation !== this.generation || fileGeneration !== this.fileGeneration || revision !== this.draftRevision)
        return;
      if (!scriptFits(script)) return this.error("script");
      this.edit({ script });
    } catch {
      if (generation === this.generation && fileGeneration === this.fileGeneration && revision === this.draftRevision)
        this.error("file");
    }
  }
  async save() {
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
    this.set({ saving: true, error: undefined });
    try {
      const reply = await this.client.update(original.id, patch);
      if (droppedRoutes(patch, reply).length) {
        // The service saved the value but not where it goes: it is a plain variable on the machine now. Keep
        // the sheet open on what is stored, so the person sees it and can remove it; never report success.
        // No automatic removal: a second write to a service that just misread the first is no safer.
        return this.set({ saving: false, original: reply, draft: environmentDraft(reply), error: "dropped" });
      }
      this.set({ saving: false });
      this.close();
    } catch (error) {
      const code = error instanceof Object && "code" in error ? error.code : undefined;
      this.set({
        saving: false,
        error: (typeof code === "string" && Object.hasOwn(refusals, code) && refusals[code]) || "save",
      });
    }
  }
}
