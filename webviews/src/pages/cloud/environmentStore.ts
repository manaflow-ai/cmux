import {
  environmentDraft,
  environmentPatch,
  scriptFits,
  SETUP_SCRIPT_BYTES,
  validateEnvironment,
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
  error?: "load" | "save" | "missing" | "name" | "names" | "script" | "file" | "copy" | "secret";
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
      const environment = options.environmentId
        ? await this.client.get(options.environmentId)
        : (await this.client.list()).find((item) => item.scope === "personal" && item.is_default);
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
    if (!this.state.draft || this.state.saving) return;
    ++this.draftRevision;
    this.set({ draft: { ...this.state.draft, ...patch }, error: undefined });
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
    const invalid = validateEnvironment(draft);
    if (invalid) return this.error(invalid);
    if (draft.secrets.some((row) => !row.value && !original.secrets.some((secret) => secret.name === row.name)))
      return this.error("secret");
    const patch = environmentPatch(original, draft);
    if (!Object.keys(patch).length) return this.close();
    this.set({ saving: true, error: undefined });
    try {
      await this.client.update(original.id, patch);
      this.set({ saving: false });
      this.close();
    } catch {
      this.set({ saving: false, error: "save" });
    }
  }
}
