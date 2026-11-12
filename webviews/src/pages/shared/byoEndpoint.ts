// Your own model endpoint as a harness (acpmux byo_endpoint.rs), the form model the Chief editor's
// Bring your own and Settings > Agents > Add > Endpoint share: the draft, the presets, the checks
// acpmux makes again, and the host's add-then-check sequence. The key goes to the host in the one
// add call (the Keychain from there): the caller clears it from its state as the call is sent.
//
// The host's add takes one `model` string: several models go comma separated, and `*` asks acpmux
// for every model the endpoint lists at its `/models`. An endpoint that takes no key (a model server
// on this Mac) is added without one: acpmux writes no key reference for it.
//
// The form picks the harness id (`endpointId`: an ASCII slug, numbered past every id acpmux has;
// a localized name may have no ASCII letters). The host refuses an id acpmux already has unless
// `replace` names it: the form sends that only for the id it added itself (a retry, or the save
// after Fetch Models). Such a retry with an empty key field keeps the key it stored (`AddTarget`).

/** `anthropic-endpoint` runs Claude Code on it; `openai-endpoint` an OpenAI-compatible client. */
export type EndpointKind = "anthropic-endpoint" | "openai-endpoint";

/** What the host's add takes for an endpoint (`cmux.chief.backend.add`). */
export interface EndpointBackend {
  kind: EndpointKind;
  name: string;
  baseUrl: string;
  /** One model id, or several comma separated (the first is the default), or `*`. */
  model: string;
  /** Absent: no key (a keyless server), or with `replace` the one the form's earlier add stored. */
  apiKey?: string;
  /** The harness id to write (the host makes one from `name` without it). */
  id?: string;
  /** The same id as `id`: write the form's own earlier add again. */
  replace?: string;
}

/** One step of `_acpmux/harness/doctor {id, prompt: true}`. */
export interface EndpointStep {
  name: string;
  ok: boolean;
  detail?: string;
  fix?: string;
}

/** The host calls an endpoint form makes; `ChiefHost` and the Chief editor service are these. */
export interface EndpointService {
  addBackend(backend: EndpointBackend): Promise<string>;
  checkBackend(id: string): Promise<{ ok: boolean; steps: EndpointStep[] }>;
  backends(): Promise<{ id: string; models: { id: string }[] }[]>;
  /** Every harness id acpmux has, from any source and of any kind (terminal harnesses too, which
   * `backends()` leaves out): the set a new endpoint's id must be past. */
  harnessIds(): Promise<string[]>;
}

/** The model-list entry acpmux fills in with every model the endpoint lists. */
export const ALL_MODELS = "*";
/** The OpenCode provider acpmux names an OpenAI-compatible endpoint's models under (`byo/<id>`). */
const PROVIDER_PREFIX = "byo/";

/** Whether the endpoint needs a key: `none` (a server on this Mac), `optional` or `required`. */
export type KeyNeed = "none" | "optional" | "required";

export type EndpointPresetId = "local-server" | "desktop-app" | "team-server" | "hosted" | "gateway";

export interface EndpointPreset {
  id: EndpointPresetId;
  kind: EndpointKind;
  /** The URL the form starts with ("" for one the person types). */
  baseUrl: string;
  /** The URL field's example when it starts empty. */
  example: string;
  key: KeyNeed;
  /** The harness id when the typed name makes none (a localized name): ASCII, never localized. */
  idBase: string;
}

/** The Endpoint tab's presets, in the order the picker lists them. */
export const ENDPOINT_PRESETS: readonly EndpointPreset[] = [
  {
    id: "local-server",
    kind: "openai-endpoint",
    baseUrl: "http://127.0.0.1:11434/v1",
    example: "http://127.0.0.1:11434/v1",
    key: "none",
    idBase: "local-models",
  },
  {
    id: "desktop-app",
    kind: "openai-endpoint",
    baseUrl: "http://127.0.0.1:1234/v1",
    example: "http://127.0.0.1:1234/v1",
    key: "none",
    idBase: "desktop-models",
  },
  {
    id: "team-server",
    kind: "openai-endpoint",
    baseUrl: "",
    example: "https://inference.example.com/v1",
    key: "optional",
    idBase: "team-models",
  },
  {
    id: "hosted",
    kind: "openai-endpoint",
    baseUrl: "",
    example: "https://api.example.com/v1",
    key: "required",
    idBase: "hosted-models",
  },
  {
    id: "gateway",
    kind: "anthropic-endpoint",
    baseUrl: "",
    example: "https://gateway.example.com",
    key: "required",
    idBase: "claude-gateway",
  },
];

export function endpointPreset(id: EndpointPresetId): EndpointPreset {
  return ENDPOINT_PRESETS.find((preset) => preset.id === id) ?? ENDPOINT_PRESETS[0]!;
}

/** The form as the person fills it in. `models` is the typed list (commas, spaces or lines). */
export interface EndpointDraft {
  kind: EndpointKind;
  name: string;
  baseUrl: string;
  models: string;
  apiKey: string;
}

/**
 * The draft after `patch`. Another base URL drops the typed key: a key reaches only the URL it was
 * typed for, so it is typed again for the new one (a patch may set both). Every endpoint form
 * (Settings › Agents › Add › Endpoint, Home Chief › Bring your own) changes its draft through this.
 */
export function patchDraft<T extends { baseUrl: string; apiKey: string }>(before: T, patch: Partial<T>): T {
  const moved = patch.baseUrl !== undefined && patch.baseUrl !== before.baseUrl;
  return { ...before, ...(moved ? { apiKey: "" } : {}), ...patch };
}

/** The model ids of a typed list, in order, without repeats. */
export function modelList(text: string): string[] {
  const out: string[] = [];
  for (const word of text.split(/[\s,]+/)) if (word && !out.includes(word)) out.push(word);
  return out;
}

/** acpmux's model id rule (byo_endpoint.rs `check_model`): one word, no quotes, braces or `$`. */
export function validModel(id: string): boolean {
  return id.length > 0 && id.length <= 200 && !/[\s{}$"'\\]/.test(id);
}

/** acpmux's URL rule (`check_base_url`): https, or http only to this machine; no user or key. */
export function endpointUrlProblem(url: string): "missing" | "invalid" | "insecure" | null {
  const text = url.trim();
  if (!text) return "missing";
  let parsed: URL;
  try {
    parsed = new URL(text);
  } catch {
    return "invalid";
  }
  if (parsed.username || parsed.password || parsed.hash || /[{}$"\\]/.test(text)) return "invalid";
  const local = ["localhost", "127.0.0.1", "[::1]", "::1"].includes(parsed.hostname);
  if (parsed.protocol === "https:") return null;
  if (parsed.protocol === "http:") return local ? null : "insecure";
  return "invalid";
}

/** What keeps the draft from being sent, first problem first; null when it can go. */
export function endpointProblem(
  draft: EndpointDraft,
  key: KeyNeed,
): "name" | "baseUrl" | "insecure" | "models" | "key" | null {
  if (!draft.name.trim()) return "name";
  const url = endpointUrlProblem(draft.baseUrl);
  if (url === "insecure") return "insecure";
  if (url) return "baseUrl";
  const models = modelList(draft.models);
  if (models.length === 0 || !models.every(validModel)) return "models";
  if (key === "required" && !draft.apiKey.trim()) return "key";
  return null;
}

/** `endpointProblem` for a form that may hold its own earlier add: a key it stored counts. */
export function endpointProblemAt(draft: EndpointDraft, key: KeyNeed, target: AddTarget | null) {
  const problem = endpointProblem(draft, key);
  return problem === "key" && keyReady(draft, key, target) ? null : problem;
}

/** Whether the endpoint's model list can be asked for: the URL, and the key when it needs one. */
export function canFetchModels(draft: EndpointDraft, key: KeyNeed, target: AddTarget | null = null): boolean {
  return !!draft.name.trim() && !endpointUrlProblem(draft.baseUrl) && keyReady(draft, key, target);
}

/** acpmux's harness id rule: 1-40 lowercase letters, digits and dashes. */
export function idSlug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+/, "")
    .slice(0, 36)
    .replace(/-+$/, "");
}

/** A new harness id from the typed name, else `fallback` (a preset's or kind's ASCII id), numbered
 * (`-2`, `-3`…) past every id in `taken`. */
export function endpointId(name: string, fallback: string, taken: Iterable<string>): string {
  const used = new Set(taken);
  const base = idSlug(name) || idSlug(fallback) || "endpoint";
  if (!used.has(base)) return base;
  for (let n = 2; ; n += 1) if (!used.has(`${base}-${n}`)) return `${base}-${n}`;
}

/** Which harness an add writes: a new id, or the one this form added earlier (`own`), and whether
 * that earlier add stored a key the person typed. */
export type AddTarget = { id: string; own: boolean; typedKey: boolean };

/** Whether the key field may stay empty: the endpoint takes none or it is optional, or this form
 * already stored one the person typed (a retry keeps it). */
export function keyReady(draft: EndpointDraft, key: KeyNeed, target: AddTarget | null): boolean {
  return key !== "required" || !!draft.apiKey.trim() || !!(target?.own && target.typedKey);
}

/** The host's add for the draft at `target`; `models` overrides the typed list (`[ALL_MODELS]` to
 * fetch). An empty key field sends no key: acpmux then writes none, or on the form's own retry
 * (`replace`) keeps the one it stored. */
export function endpointBackend(
  draft: EndpointDraft,
  target?: AddTarget,
  models: string[] = modelList(draft.models),
): EndpointBackend {
  const typed = draft.apiKey.trim();
  return {
    kind: draft.kind,
    name: draft.name.trim(),
    baseUrl: draft.baseUrl.trim(),
    model: models.join(","),
    ...(typed ? { apiKey: typed } : {}),
    ...(target ? { id: target.id } : {}),
    ...(target?.own ? { replace: target.id } : {}),
  };
}

/** After an add at `target` with `backend`: the form's own harness from now on, keeping whether a
 * typed key is stored there. */
export function addedTarget(target: AddTarget, backend: EndpointBackend): AddTarget {
  return { id: target.id, own: true, typedKey: !!backend.apiKey || target.typedKey };
}

/** A harness's model ids as the form lists them (acpmux names an OpenAI-compatible one `byo/<id>`). */
/** The model id the harness declares for one the form lists, the id a Chief saves: OpenCode
 * names every model of an OpenAI-compatible endpoint `byo/<id>`; Claude Code takes the id as typed.
 * `*` (every model) is none: the harness's own default. */
export function declaredModelId(kind: EndpointKind, model: string): string {
  if (!model || model === ALL_MODELS) return "";
  // Always prefixed: acpmux declares every listed id under the provider, a raw `byo/coder` too
  // (`byo/byo/coder`).
  return kind === "openai-endpoint" ? `${PROVIDER_PREFIX}${model}` : model;
}

export function endpointModelIds(kind: EndpointKind, models: { id: string }[]): string[] {
  return models.map((model) =>
    kind === "openai-endpoint" && model.id.startsWith(PROVIDER_PREFIX)
      ? model.id.slice(PROVIDER_PREFIX.length)
      : model.id,
  );
}

/** Where an endpoint form is: editing, asking the host, or the check's answer. */
export type EndpointStatus =
  | { state: "editing" }
  | { state: "fetching" }
  | { state: "adding" }
  | { state: "checking"; harness: string }
  | { state: "passed"; harness: string }
  | { state: "failed"; harness?: string; step?: EndpointStep };

export const endpointBusy = (status: EndpointStatus) =>
  status.state === "fetching" || status.state === "adding" || status.state === "checking";

/** A host refusal's text: an Error's or a page error's `message`, else the value as text. */
export const failureText = (failure: unknown) =>
  failure && typeof failure === "object" && typeof (failure as { message?: unknown }).message === "string"
    ? (failure as { message: string }).message
    : String(failure);

/** The host's real hello turn for `harness`: `passed`, or `failed` with the first failing step. */
export async function checkEndpoint(
  service: Pick<EndpointService, "checkBackend">,
  harness: string,
): Promise<EndpointStatus> {
  try {
    const result = await service.checkBackend(harness);
    if (result.ok) return { state: "passed", harness };
    return { state: "failed", harness, step: result.steps.find((step) => !step.ok) };
  } catch (failure) {
    return { state: "failed", harness, step: { name: "doctor", ok: false, detail: failureText(failure) } };
  }
}

/** Adds the backend (the key to the Keychain on the host) and runs its hello turn, reporting each
 * state; answers the last one: `passed` with the harness, or `failed` with the step. */
export async function bringEndpoint(
  service: Pick<EndpointService, "addBackend" | "checkBackend">,
  backend: { kind: string; name: string; id?: string; replace?: string; apiKey?: string },
  report: (status: EndpointStatus) => void,
  added: (harness: string) => void = () => {},
): Promise<EndpointStatus> {
  report({ state: "adding" });
  let harness: string;
  try {
    harness = await service.addBackend(backend as EndpointBackend);
  } catch (failure) {
    // Not the form's: only an add that answered is (a failed one may have hit an id it never got).
    const failed: EndpointStatus = { state: "failed", step: { name: "add", ok: false, detail: failureText(failure) } };
    report(failed);
    return failed;
  }
  // The harness exists from here on, before the check: a form closed meanwhile still removes it.
  added(harness);
  report({ state: "checking", harness });
  const checked = await checkEndpoint(service, harness);
  report(checked);
  return checked;
}

/** A new id for the draft, past every harness acpmux has from any source (`fallback`: the preset's
 * or kind's). */
export async function newTarget(
  service: Pick<EndpointService, "harnessIds">,
  name: string,
  fallback: string,
): Promise<AddTarget> {
  return newTargetPast(name, fallback, await service.harnessIds());
}

/** A new id for the draft past `taken` (every harness id acpmux has). */
export function newTargetPast(name: string, fallback: string, taken: readonly string[]): AddTarget {
  return { id: endpointId(name, fallback, taken), own: false, typedKey: false };
}

/** Fetch models: adds the endpoint at `target` with `*` (acpmux reads its `/models` with the key
 * just stored and lists them all), then reads the harness's models back. Answers the ids and the
 * target the form owns from now on (the save writes it again with the models kept; a form closed
 * without saving removes it), or throws the host's reason. */
export async function fetchEndpointModels(
  service: Pick<EndpointService, "addBackend" | "backends">,
  draft: EndpointDraft,
  target: AddTarget,
  added: (harness: string) => void = () => {},
): Promise<{ models: string[]; target: AddTarget }> {
  const backend = endpointBackend(draft, target, [ALL_MODELS]);
  // Owned only once the add answers (a failed add is never the form's), before the read below.
  const harness = await service.addBackend(backend);
  added(harness);
  const listed = (await service.backends()).find((entry) => entry.id === harness);
  return {
    models: endpointModelIds(draft.kind, listed?.models ?? []),
    target: addedTarget({ ...target, id: harness }, backend),
  };
}
