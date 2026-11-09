// Your own model endpoint as a harness (acpmux byo_endpoint.rs), the form model the Chief editor's
// Bring your own and Settings > Agents > Add > Endpoint share: the draft, the presets, the checks
// acpmux makes again, and the host's add-then-check sequence. The key goes to the host in the one
// add call (the Keychain from there): the caller clears it from its state as the call is sent.
//
// The host's add takes one `model` string: several models go comma separated, and `*` asks acpmux
// for every model the endpoint lists at its `/models`. The host's add also requires a key, so an
// endpoint that takes none (a model server on this Mac) gets NO_KEY, which it ignores.

/** `anthropic-endpoint` runs Claude Code on it; `openai-endpoint` an OpenAI-compatible client. */
export type EndpointKind = "anthropic-endpoint" | "openai-endpoint";

/** What the host's add takes for an endpoint (`cmux.chief.backend.add`). */
export interface EndpointBackend {
  kind: EndpointKind;
  name: string;
  baseUrl: string;
  /** One model id, or several comma separated (the first is the default), or `*`. */
  model: string;
  apiKey: string;
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
}

/** The model-list entry acpmux fills in with every model the endpoint lists. */
export const ALL_MODELS = "*";
/** The key an endpoint that takes none gets: the host's add requires one, the server ignores it. */
export const NO_KEY = "no-key";
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
}

/** The Endpoint tab's presets, in the order the picker lists them. */
export const ENDPOINT_PRESETS: readonly EndpointPreset[] = [
  {
    id: "local-server",
    kind: "openai-endpoint",
    baseUrl: "http://127.0.0.1:11434/v1",
    example: "http://127.0.0.1:11434/v1",
    key: "none",
  },
  {
    id: "desktop-app",
    kind: "openai-endpoint",
    baseUrl: "http://127.0.0.1:1234/v1",
    example: "http://127.0.0.1:1234/v1",
    key: "none",
  },
  {
    id: "team-server",
    kind: "openai-endpoint",
    baseUrl: "",
    example: "https://inference.example.com/v1",
    key: "optional",
  },
  { id: "hosted", kind: "openai-endpoint", baseUrl: "", example: "https://api.example.com/v1", key: "required" },
  { id: "gateway", kind: "anthropic-endpoint", baseUrl: "", example: "https://gateway.example.com", key: "required" },
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

/** Whether the endpoint's model list can be asked for: the URL, and the key when it needs one. */
export function canFetchModels(draft: EndpointDraft, key: KeyNeed): boolean {
  return !!draft.name.trim() && !endpointUrlProblem(draft.baseUrl) && (key !== "required" || !!draft.apiKey.trim());
}

/** The host's add for the draft; `models` overrides the typed list (`[ALL_MODELS]` to fetch). */
export function endpointBackend(draft: EndpointDraft, models: string[] = modelList(draft.models)): EndpointBackend {
  return {
    kind: draft.kind,
    name: draft.name.trim(),
    baseUrl: draft.baseUrl.trim(),
    model: models.join(","),
    apiKey: draft.apiKey.trim() || NO_KEY,
  };
}

/** A harness's model ids as the form lists them (acpmux names an OpenAI-compatible one `byo/<id>`). */
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
  backend: { kind: string; name: string },
  report: (status: EndpointStatus) => void,
): Promise<EndpointStatus> {
  report({ state: "adding" });
  let harness: string;
  try {
    harness = await service.addBackend(backend as EndpointBackend);
  } catch (failure) {
    const failed: EndpointStatus = { state: "failed", step: { name: "add", ok: false, detail: failureText(failure) } };
    report(failed);
    return failed;
  }
  report({ state: "checking", harness });
  const checked = await checkEndpoint(service, harness);
  report(checked);
  return checked;
}

/** Fetch models: adds the endpoint with `*` (acpmux reads its `/models` with the key just stored
 * and lists them all), then reads the harness's models back. Answers the ids, or throws the host's
 * reason. The save that follows writes the profile again with the models the person kept. */
export async function fetchEndpointModels(
  service: Pick<EndpointService, "addBackend" | "backends">,
  draft: EndpointDraft,
): Promise<string[]> {
  const harness = await service.addBackend(endpointBackend(draft, [ALL_MODELS]));
  const listed = (await service.backends()).find((backend) => backend.id === harness);
  return endpointModelIds(draft.kind, listed?.models ?? []);
}
