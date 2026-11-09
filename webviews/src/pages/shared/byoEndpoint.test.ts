// The endpoint form model shared by the Chief editor's Bring your own and Settings > Agents > Add >
// Endpoint (plan api-and-open-models gaps 3 and 6).
import { expect, test } from "bun:test";
import {
  ENDPOINT_PRESETS,
  bringEndpoint,
  addedTarget,
  canFetchModels,
  endpointBackend,
  endpointId,
  endpointProblemAt,
  endpointModelIds,
  endpointProblem,
  endpointUrlProblem,
  fetchEndpointModels,
  modelList,
  type EndpointBackend,
  type EndpointDraft,
  type EndpointStatus,
} from "./byoEndpoint";

const draft = (patch: Partial<EndpointDraft> = {}): EndpointDraft => ({
  kind: "openai-endpoint",
  name: "Local",
  baseUrl: "http://127.0.0.1:11434/v1",
  models: "a",
  apiKey: "",
  ...patch,
});

test("presets name no product, and the local ones need no key", () => {
  expect(ENDPOINT_PRESETS.map((preset) => preset.id)).toEqual([
    "local-server",
    "desktop-app",
    "team-server",
    "hosted",
    "gateway",
  ]);
  expect(ENDPOINT_PRESETS.find((preset) => preset.id === "local-server")!.baseUrl).toContain(":11434/v1");
  expect(ENDPOINT_PRESETS.find((preset) => preset.id === "desktop-app")!.baseUrl).toContain(":1234/v1");
  expect(ENDPOINT_PRESETS.filter((preset) => preset.key === "none").map((preset) => preset.id)).toEqual([
    "local-server",
    "desktop-app",
  ]);
  expect(ENDPOINT_PRESETS.find((preset) => preset.id === "gateway")!.kind).toBe("anthropic-endpoint");
});

test("a typed model list splits on commas, spaces and lines, in order, without repeats", () => {
  expect(modelList(" big, mid\nsmall  big,,")).toEqual(["big", "mid", "small"]);
  expect(modelList("")).toEqual([]);
});

test("the URL rule is acpmux's: https, or plain http only to this machine", () => {
  expect(endpointUrlProblem("https://api.example.com/v1")).toBeNull();
  expect(endpointUrlProblem("http://localhost:1234/v1")).toBeNull();
  expect(endpointUrlProblem("http://[::1]:8080")).toBeNull();
  expect(endpointUrlProblem("http://llm.example.com/v1")).toBe("insecure");
  expect(endpointUrlProblem("")).toBe("missing");
  expect(endpointUrlProblem("llm.example.com")).toBe("invalid");
  expect(endpointUrlProblem("https://me:pw@llm.example.com")).toBe("invalid");
  expect(endpointUrlProblem("https://llm.example.com/${HOME}")).toBe("invalid");
  expect(endpointUrlProblem("ftp://llm.example.com")).toBe("invalid");
});

test("the draft is complete with a name, a URL, valid models and, when needed, a key", () => {
  expect(endpointProblem(draft(), "none")).toBeNull();
  expect(endpointProblem(draft({ name: " " }), "none")).toBe("name");
  expect(endpointProblem(draft({ baseUrl: "http://far.example.com" }), "none")).toBe("insecure");
  expect(endpointProblem(draft({ models: "" }), "none")).toBe("models");
  expect(endpointProblem(draft({ models: "ok {env:HOME}" }), "none")).toBe("models");
  expect(endpointProblem(draft(), "required")).toBe("key");
  expect(endpointProblem(draft({ apiKey: "k" }), "required")).toBeNull();
  expect(endpointProblem(draft(), "optional")).toBeNull();
  expect(canFetchModels(draft({ models: "" }), "none")).toBe(true);
  expect(canFetchModels(draft({ models: "" }), "required")).toBe(false);
});

test("the host's add gets the models comma separated and no key for a keyless endpoint", () => {
  expect(endpointBackend(draft({ models: "big mid", name: " Local " }))).toEqual({
    kind: "openai-endpoint",
    name: "Local",
    baseUrl: "http://127.0.0.1:11434/v1",
    model: "big,mid",
  });
  expect(endpointBackend(draft({ apiKey: " key " }), undefined, ["*"])).toMatchObject({ model: "*", apiKey: "key" });
  expect(endpointModelIds("openai-endpoint", [{ id: "byo/org/m" }, { id: "plain" }])).toEqual(["org/m", "plain"]);
  expect(endpointModelIds("anthropic-endpoint", [{ id: "byo/x" }])).toEqual(["byo/x"]);
});

function service(check: { ok: boolean; steps: { name: string; ok: boolean; detail?: string }[] }) {
  const added: EndpointBackend[] = [];
  return {
    added,
    addBackend: async (backend: EndpointBackend) => {
      added.push(backend);
      if (backend.name === "refused") throw { code: "cmux.agents.exists", message: "refused already has a profile" };
      return backend.name.toLowerCase();
    },
    checkBackend: async () => check,
    backends: async () => [{ id: "local", models: [{ id: "byo/one" }, { id: "byo/two" }] }],
  };
}

test("bring adds, then checks; it reports each state and the first failing step", async () => {
  const seen: EndpointStatus["state"][] = [];
  const passing = service({ ok: true, steps: [{ name: "prompt", ok: true }] });
  const done = await bringEndpoint(passing, endpointBackend(draft()), (status) => seen.push(status.state));
  expect(done).toEqual({ state: "passed", harness: "local" });
  expect(seen).toEqual(["adding", "checking", "passed"]);

  const failing = service({
    ok: false,
    steps: [
      { name: "launch", ok: true },
      { name: "prompt", ok: false, detail: "401" },
    ],
  });
  expect(await bringEndpoint(failing, endpointBackend(draft()), () => {})).toEqual({
    state: "failed",
    harness: "local",
    step: { name: "prompt", ok: false, detail: "401" },
  });
  // A refused add (a page error, not an Error) names the add step with the host's text.
  expect(await bringEndpoint(failing, endpointBackend(draft({ name: "refused" })), () => {})).toEqual({
    state: "failed",
    step: { name: "add", ok: false, detail: "refused already has a profile" },
  });
});

test("fetch adds the endpoint with * at the form's id and reads its models back", async () => {
  const host = service({ ok: true, steps: [] });
  const fetched = await fetchEndpointModels(host, draft({ models: "" }), { id: "local", own: false, typedKey: false });
  expect(fetched).toEqual({ models: ["one", "two"], target: { id: "local", own: true, typedKey: false } });
  expect(host.added[0]).toEqual({
    kind: "openai-endpoint",
    name: "Local",
    baseUrl: "http://127.0.0.1:11434/v1",
    model: "*",
    id: "local",
  });
});

test("a new id is an ASCII slug numbered past every harness, never a localized name's my-backend", () => {
  expect(endpointId("Local Models", "local-models", [])).toBe("local-models");
  expect(endpointId("Local Models", "local-models", ["local-models", "local-models-2"])).toBe("local-models-3");
  // A name with no ASCII letters (ja, zh, ko): the preset's own id.
  expect(endpointId("ローカルモデル", "local-models", [])).toBe("local-models");
  expect(endpointId("ホスト型モデル", "hosted-models", ["hosted-models"])).toBe("hosted-models-2");
  expect(endpointId("", "", [])).toBe("endpoint");
  expect(endpointId("x".repeat(60), "f", []).length).toBeLessThanOrEqual(40);
});

test("only the form's own earlier add is replaced, and a retry keeps the key it stored", () => {
  const fresh = { id: "team-models", own: false, typedKey: false };
  // A new add names its id and replaces nothing.
  const first = endpointBackend(draft({ apiKey: "real-key" }), fresh);
  expect(first).toMatchObject({ id: "team-models", apiKey: "real-key" });
  expect(first.replace).toBeUndefined();
  const mine = addedTarget(fresh, first);
  expect(mine).toEqual({ id: "team-models", own: true, typedKey: true });
  // The retry with the field cleared: replace that id and send no key (never no-key over it).
  const retry = endpointBackend(draft(), mine);
  expect(retry).toMatchObject({ id: "team-models", replace: "team-models" });
  expect("apiKey" in retry).toBe(false);
  expect(addedTarget(mine, retry).typedKey).toBe(true);
  // A new key typed on the retry replaces the stored one.
  expect(endpointBackend(draft({ apiKey: "new-key" }), mine)).toMatchObject({ apiKey: "new-key" });
  // A required key may stay empty only when this form stored one.
  expect(endpointProblemAt(draft(), "required", null)).toBe("key");
  expect(endpointProblemAt(draft(), "required", mine)).toBeNull();
  // A keyless server: no key on the first add or the retry (acpmux writes no key reference).
  const keyless = addedTarget(fresh, endpointBackend(draft(), fresh));
  expect(keyless.typedKey).toBe(false);
  const again = endpointBackend(draft(), keyless);
  expect(again).toMatchObject({ replace: "team-models" });
  expect("apiKey" in again).toBe(false);
});
