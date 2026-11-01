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
  error?: "load" | "save" | "missing" | "name" | "names" | "script" | "file" | "copy" | "secret" | "switch";
  errorCode?: string;
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
    // The cog and checklist can both request the same editor while it is already
    // open. Keep the single draft and only change the drilled section/options.
    if (this.state.open && this.state.draft && this.state.original && this.isSameTarget(options)) {
      const previous = this.options;
      this.options = options;
      const repositoryChanged = previous.repo !== options.repo || previous.ref !== options.ref;
      this.set({ section: options.section ?? "overview", error: undefined, errorCode: undefined });
      if (repositoryChanged && this.state.original.setup_script === null && this.state.draft.script === null) {
        ++this.generation;
        this.set({ derivedScript: undefined, deriving: false, deriveFailed: false });
        if (options.repo) void this.derive();
      }
      return;
    }
    if (this.state.open && this.state.draft && this.state.original && this.isDirty()) {
      // Keep the current draft visible rather than silently throwing it away when
      // another caller asks to edit a different environment.
      this.set({ error: "switch", errorCode: undefined });
      return;
    }
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
    this.set({ draft: { ...this.state.draft, ...patch }, error: undefined, errorCode: undefined });
  };
  error = (error: EnvironmentState["error"]) => this.set({ error, errorCode: undefined });
  private isDirty() {
    const { original, draft } = this.state;
    if (!original || !draft) return false;
    const initial = environmentDraft(original);
    return JSON.stringify(draft) !== JSON.stringify(initial);
  }
  private isSameTarget(options: EnvironmentOpen) {
    const original = this.state.original;
    if (!original) return false;
    if (options.environmentId) return options.environmentId === original.id;
    return original.scope === "personal" && original.is_default;
  }
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
    this.set({ saving: true, error: undefined, errorCode: undefined });
    try {
      await this.client.update(original.id, patch);
      this.set({ saving: false });
      this.close();
    } catch (caught) {
      const code =
        caught && typeof caught === "object" && "code" in caught && typeof caught.code === "string"
          ? caught.code
          : undefined;
      this.set({ saving: false, error: "save", errorCode: code });
    }
  }
}
