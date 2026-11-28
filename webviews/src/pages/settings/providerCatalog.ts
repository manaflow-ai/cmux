import type { ModelDeviceProvider, ModelProvider } from "./ops";
import { t } from "./strings";

export const providerGroups = ["subscriptions", "codingPlans", "keys", "gateways", "local"] as const;
type ProviderGroup = (typeof providerGroups)[number];

export type ProviderRegion = {
  id: string;
  label: string;
  baseUrl: string;
  keyUrl: string;
  legacyBaseUrl?: string;
};

type ConnectMethod = "key" | "device" | "claude" | "local";

type ConnectDialog = {
  title: string;
  titleName?: string;
  description: string;
  method: ConnectMethod;
  fields: readonly ("key" | "region" | "url" | "models" | "deployments" | "gateway" | "name")[];
};

const dialogKey = (suffix: string) => `settingsWindow.models.dialog.${suffix}`;

function dialog(
  id: string,
  titleName: string,
  method: ConnectMethod,
  fields: ConnectDialog["fields"] = [],
  options: { title?: string } = {},
): ConnectDialog {
  return {
    title: dialogKey(`title.${options.title ?? "with"}`),
    titleName: titleName || undefined,
    description: dialogKey(`${id}.description`),
    method,
    fields,
  };
}

const region = (id: string, baseUrl: string, keyUrl: string, legacyBaseUrl?: string): ProviderRegion => ({
  id,
  label: dialogKey(`region.${id}`),
  baseUrl,
  keyUrl,
  legacyBaseUrl,
});

const bedrockRegions = [
  "us-east-1",
  "us-east-2",
  "us-west-2",
  "ap-northeast-1",
  "ap-south-1",
  "ap-southeast-3",
  "eu-central-1",
  "eu-west-1",
  "eu-west-2",
  "eu-south-1",
  "eu-north-1",
  "sa-east-1",
].map((id) => ({
  id,
  label: id,
  baseUrl: `https://bedrock-mantle.${id}.api.aws/v1`,
  keyUrl: `https://console.aws.amazon.com/bedrock/home?region=${id}`,
}));

const minimaxRegions = (plan: boolean) => [
  region(
    "minimaxGlobal",
    `https://api.minimax.io/${plan ? "anthropic" : "v1"}`,
    `https://platform.minimax.io/${plan ? "subscribe/token-plan" : "console/keys"}`,
    plan ? "https://api.minimax.io/anthropic/v1" : undefined,
  ),
  region(
    "minimaxChina",
    `https://api.minimaxi.com/${plan ? "anthropic" : "v1"}`,
    `https://platform.minimaxi.com/${plan ? "subscribe/token-plan" : "console/api-key"}`,
    plan ? "https://api.minimaxi.com/anthropic/v1" : undefined,
  ),
];

const zaiRegions = (plan: boolean) => [
  region("zaiGlobal", `https://api.z.ai/api/${plan ? "coding/" : ""}paas/v4`, "https://z.ai/manage-apikey/apikey-list"),
  region(
    "zaiChina",
    `https://open.bigmodel.cn/api/${plan ? "coding/" : ""}paas/v4`,
    "https://open.bigmodel.cn/usercenter/apikeys",
  ),
];

type ProviderDetails = {
  dialog: ConnectDialog;
  regions?: readonly ProviderRegion[];
  accountRegion?: true;
  id: string;
  name: string;
  group: ProviderGroup;
  baseUrl: string | null;
  keyUrl: string | null;
  docsUrl: string | null;
  /** A brand from design/agent-icons, or a neutral Settings glyph for a provider with no brand. */
  mark: { agent: string } | { icon: string };
  families: readonly string[];
  /** Picker families whose Connect shortcut goes directly to this preset. */
  aliases?: readonly string[];
  /** A stored CLI login appears as a detected row in Models. */
  detectedOnly?: true;
  disabledReason?: string;
  cloud: boolean;
};

export type KeyProvider = ProviderDetails & {
  id: ModelProvider;
  kind: "api-key";
  baseUrl: string;
  keyUrl: string;
};

export type OpenAIEndpoint = ProviderDetails & {
  kind: "openai-endpoint";
  keyRequired: boolean;
  urlHint?: string;
  deploymentName?: true;
  defaultModels?: readonly string[];
};

export type LocalSignIn = "claude" | "codex" | "gemini";

export type CatalogProvider =
  | (ProviderDetails & { kind: "subscription"; signIn: ModelDeviceProvider | LocalSignIn })
  | KeyProvider
  | OpenAIEndpoint
  | (ProviderDetails & {
      kind: "claude-login";
    });

function endpoint(
  details: Pick<
    ProviderDetails,
    "id" | "name" | "baseUrl" | "keyUrl" | "docsUrl" | "dialog" | "regions" | "accountRegion"
  > & {
    group?: ProviderGroup;
    mark: ProviderDetails["mark"];
    aliases?: readonly string[];
    urlHint?: string;
    deploymentName?: true;
    defaultModels?: readonly string[];
  },
): OpenAIEndpoint {
  const { group = "keys", ...provider } = details;
  const connect = provider.dialog;
  const fields =
    connect.fields.includes("deployments") || connect.fields.includes("models")
      ? connect.fields
      : ([...connect.fields, "models"] as const);
  return {
    ...provider,
    dialog: { ...connect, fields },
    group,
    kind: "openai-endpoint",
    families: ["opencode"],
    cloud: false,
    keyRequired: group !== "local",
  };
}

/** A custom endpoint has no brand: the Settings globe, in the text colour. */
export const ENDPOINT_MARK: ProviderDetails["mark"] = { icon: "globe" };

// Installed route support comes from acpmux's connections.rs (PROVIDERS and serves_cloud).
// OpenAI-compatible presets use the local OpenCode profile written by byo_endpoint.rs.
export const providerCatalog: readonly CatalogProvider[] = [
  {
    id: "chatgpt",
    dialog: dialog("chatgpt", "ChatGPT", "device"),
    name: "ChatGPT",
    group: "subscriptions",
    kind: "subscription",
    signIn: "chatgpt",
    baseUrl: "https://chatgpt.com",
    keyUrl: null,
    docsUrl: "https://learn.chatgpt.com/docs/auth",
    mark: { agent: "openai" },
    families: ["codex"],
    cloud: true,
  },
  {
    id: "claude",
    dialog: dialog("claude", "Claude", "claude"),
    name: "Claude",
    group: "subscriptions",
    kind: "claude-login",
    baseUrl: "https://claude.ai",
    keyUrl: null,
    docsUrl: "https://code.claude.com/docs/en/cli-reference",
    mark: { agent: "claude" },
    families: ["claude"],
    cloud: true,
  },
  {
    id: "grok",
    disabledReason: "settingsWindow.models.catalog.disabled",
    dialog: dialog("grok", "SuperGrok", "device"),
    name: "SuperGrok",
    group: "subscriptions",
    kind: "subscription",
    signIn: "grok",
    baseUrl: "https://grok.com",
    keyUrl: null,
    docsUrl: "https://grok.com/plans",
    mark: { agent: "grok" },
    families: ["grok"],
    cloud: false,
  },
  {
    id: "copilot",
    disabledReason: "settingsWindow.models.catalog.disabled",
    dialog: dialog("copilot", "GitHub Copilot", "device"),
    name: "GitHub Copilot",
    group: "subscriptions",
    kind: "subscription",
    signIn: "copilot",
    baseUrl: "https://github.com",
    keyUrl: null,
    docsUrl: "https://github.com/settings/copilot",
    mark: { agent: "copilot" },
    families: ["opencode"],
    cloud: false,
  },
  {
    id: "claude-login",
    dialog: dialog("claude-login", "Claude", "local"),
    name: "Claude",
    group: "subscriptions",
    kind: "subscription",
    signIn: "claude",
    baseUrl: "https://claude.ai",
    keyUrl: null,
    docsUrl: "https://code.claude.com/docs/en/authentication",
    mark: { agent: "claude" },
    families: ["claude"],
    detectedOnly: true,
    cloud: true,
  },
  {
    id: "codex-login",
    dialog: dialog("codex-login", "ChatGPT", "local"),
    name: "ChatGPT",
    group: "subscriptions",
    kind: "subscription",
    signIn: "codex",
    baseUrl: "https://chatgpt.com",
    keyUrl: null,
    docsUrl: "https://learn.chatgpt.com/docs/auth",
    mark: { agent: "openai" },
    families: ["codex"],
    detectedOnly: true,
    cloud: true,
  },
  {
    id: "gemini-login",
    dialog: dialog("gemini-login", "Gemini CLI", "local"),
    name: "Gemini CLI",
    group: "subscriptions",
    kind: "subscription",
    signIn: "gemini",
    baseUrl: "https://accounts.google.com",
    keyUrl: null,
    docsUrl: "https://geminicli.com/docs/get-started/authentication/",
    mark: { agent: "gemini" },
    families: ["gemini"],
    detectedOnly: true,
    cloud: false,
  },
  endpoint({
    id: "opencode-go",
    dialog: dialog("opencode-go", "OpenCode Go", "key", ["key"]),
    name: "OpenCode Go",
    group: "codingPlans",
    mark: { agent: "opencode" },
    aliases: ["opencode"],
    baseUrl: "https://opencode.ai/inference/go/openai/v1",
    keyUrl: "https://opencode.ai/console",
    docsUrl: "https://opencode.ai/docs/console/harnesses/",
  }),
  endpoint({
    id: "glm-coding-plan",
    dialog: dialog("glm-coding-plan", "GLM Coding Plan", "key", ["region", "key"]),
    regions: zaiRegions(true),
    name: "GLM Coding Plan (Z.ai)",
    group: "codingPlans",
    mark: { agent: "zai" },
    baseUrl: "https://api.z.ai/api/coding/paas/v4",
    keyUrl: "https://z.ai/manage-apikey/apikey-list",
    docsUrl: "https://docs.z.ai/devpack/tool/others",
  }),
  endpoint({
    id: "kimi-code",
    dialog: dialog("kimi-code", "Kimi Code", "device", ["region", "key"]),
    accountRegion: true,
    regions: [
      region("kimiGlobal", "https://api.kimi.ai/coding/v1", "https://www.kimi.ai/code/console"),
      region("kimiChina", "https://api.kimi.com/coding/v1", "https://www.kimi.com/code/console"),
    ],
    name: "Kimi Code",
    group: "codingPlans",
    mark: { agent: "kimi" },
    baseUrl: "https://api.kimi.ai/coding/v1",
    keyUrl: "https://www.kimi.com/code/console",
    docsUrl: "https://www.kimi.com/code/docs/en/kimi-code/models.html",
    defaultModels: ["kimi-for-coding"],
  }),
  endpoint({
    id: "ollama-cloud",
    dialog: dialog("ollama-cloud", "Ollama Cloud", "key", ["key"]),
    name: "Ollama Cloud",
    group: "codingPlans",
    mark: { agent: "ollama" },
    baseUrl: "https://ollama.com/v1",
    keyUrl: "https://ollama.com/settings/keys",
    docsUrl: "https://docs.ollama.com/api/openai-compatibility",
  }),
  endpoint({
    id: "minimax-coding-plan",
    dialog: dialog("minimax-coding-plan", "MiniMax", "key", ["region", "key"]),
    regions: minimaxRegions(true),
    name: "MiniMax",
    group: "codingPlans",
    mark: { agent: "minimax" },
    baseUrl: "https://api.minimax.io/anthropic",
    keyUrl: "https://platform.minimax.io/subscribe/token-plan",
    docsUrl: "https://platform.minimax.io/docs/m-plan/opencode",
    defaultModels: ["MiniMax-M3.1-Flash"],
  }),
  endpoint({
    id: "morph",
    dialog: dialog("morph", "Morph Ultra", "key", ["key"]),
    name: "Morph Ultra",
    group: "codingPlans",
    mark: { agent: "morph" },
    baseUrl: "https://api.morphllm.com/v1",
    keyUrl: "https://morphllm.com/dashboard/api-keys",
    docsUrl: "https://www.morphllm.com/products/ultra",
    defaultModels: ["morph-kimik31", "morph-dsv41flash"],
  }),
  {
    id: "anthropic",
    dialog: dialog("anthropic", "Anthropic API", "key", ["key"], { title: "plain" }),
    name: "Anthropic",
    group: "keys",
    kind: "api-key",
    baseUrl: "https://api.anthropic.com",
    keyUrl: "https://platform.claude.com/settings/keys",
    docsUrl: "https://platform.claude.com/docs/en/api/overview",
    mark: { agent: "anthropic" },
    families: ["claude"],
    cloud: true,
  },
  {
    id: "openai",
    dialog: dialog("openai", "OpenAI API", "key", ["key"], { title: "plain" }),
    name: "OpenAI",
    group: "keys",
    kind: "api-key",
    baseUrl: "https://api.openai.com/v1",
    keyUrl: "https://platform.openai.com/api-keys",
    docsUrl: "https://platform.openai.com/docs/api-reference/introduction",
    mark: { agent: "openai" },
    families: ["codex"],
    cloud: true,
  },
  {
    id: "google",
    dialog: dialog("google", "Gemini API", "key", ["key"], { title: "plain" }),
    name: "Google (Gemini)",
    group: "keys",
    kind: "api-key",
    baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
    keyUrl: "https://aistudio.google.com/app/apikey",
    docsUrl: "https://ai.google.dev/gemini-api/docs/openai",
    mark: { agent: "gemini" },
    families: ["gemini"],
    aliases: ["gemini"],
    cloud: true,
  },
  {
    id: "vertex-express",
    dialog: dialog("vertex-express", "Vertex AI Express", "key", ["key"], { title: "plain" }),
    name: "Vertex AI Express",
    group: "keys",
    kind: "api-key",
    baseUrl: "https://aiplatform.googleapis.com",
    keyUrl: "https://console.cloud.google.com/vertex-ai/studio",
    docsUrl: "https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/express-mode/overview",
    mark: { agent: "gemini" },
    families: ["gemini"],
    cloud: true,
  },
  {
    id: "xai",
    dialog: dialog("xai", "xAI API", "key", ["key"], { title: "plain" }),
    name: "xAI",
    group: "keys",
    kind: "api-key",
    baseUrl: "https://api.x.ai/v1",
    keyUrl: "https://console.x.ai/team/default/api-keys",
    docsUrl: "https://docs.x.ai/developers/rest-api-reference/inference",
    mark: { agent: "grok" },
    families: ["grok"],
    aliases: ["grok", "grok-cli", "grok-build"],
    cloud: true,
  },
  endpoint({
    id: "deepseek",
    dialog: dialog("deepseek", "DeepSeek", "key", ["key"]),
    name: "DeepSeek",
    mark: { agent: "deepseek" },
    baseUrl: "https://api.deepseek.com",
    keyUrl: "https://platform.deepseek.com/api_keys",
    docsUrl: "https://api-docs.deepseek.com/",
  }),
  endpoint({
    id: "mistral",
    dialog: dialog("mistral", "Mistral", "key", ["region", "key"]),
    regions: [
      region("global", "https://api.mistral.ai/v1", "https://console.mistral.ai/api-keys/"),
      region("europe", "https://api.eu.mistral.ai/v1", "https://console.mistral.ai/api-keys/"),
      region("unitedStates", "https://api.us.mistral.ai/v1", "https://console.mistral.ai/api-keys/"),
    ],
    name: "Mistral",
    mark: { agent: "mistral" },
    baseUrl: "https://api.mistral.ai/v1",
    keyUrl: "https://console.mistral.ai/api-keys/",
    docsUrl: "https://docs.mistral.ai/api",
  }),
  endpoint({
    id: "groq",
    dialog: dialog("groq", "Groq", "key", ["key"]),
    name: "Groq",
    mark: { agent: "groq" },
    baseUrl: "https://api.groq.com/openai/v1",
    keyUrl: "https://console.groq.com/keys",
    docsUrl: "https://console.groq.com/docs/openai",
  }),
  endpoint({
    id: "together",
    dialog: dialog("together", "Together AI", "key", ["key"]),
    name: "Together AI",
    mark: { agent: "together" },
    baseUrl: "https://api.together.ai/v1",
    keyUrl: "https://api.together.ai/settings/projects/~current/api-keys",
    docsUrl: "https://docs.together.ai/docs/openai-api-compatibility",
  }),
  endpoint({
    id: "fireworks",
    dialog: dialog("fireworks", "Fireworks", "key", ["key"]),
    name: "Fireworks",
    mark: { agent: "fireworks" },
    baseUrl: "https://api.fireworks.ai/inference/v1",
    keyUrl: "https://app.fireworks.ai/settings/users/api-keys",
    docsUrl: "https://docs.fireworks.ai/getting-started/quickstart",
  }),
  endpoint({
    id: "cerebras",
    dialog: dialog("cerebras", "Cerebras", "key", ["key"]),
    name: "Cerebras",
    mark: { agent: "cerebras" },
    baseUrl: "https://api.cerebras.ai/v1",
    keyUrl: "https://cloud.cerebras.ai/",
    docsUrl: "https://inference-docs.cerebras.ai/quickstart",
  }),
  endpoint({
    id: "moonshot",
    dialog: dialog("moonshot", "Kimi Platform", "key", ["region", "key"]),
    accountRegion: true,
    regions: [
      region("international", "https://api.moonshot.ai/v1", "https://platform.kimi.ai/console/api-keys"),
      region("mainlandChina", "https://api.moonshot.cn/v1", "https://platform.moonshot.cn/console/api-keys"),
    ],
    name: "Kimi Platform",
    mark: { agent: "kimi" },
    baseUrl: "https://api.moonshot.ai/v1",
    keyUrl: "https://platform.kimi.ai/console/api-keys",
    docsUrl: "https://platform.moonshot.ai/docs/guide/start-using-kimi-api",
  }),
  endpoint({
    id: "zai",
    dialog: dialog("zai", "Z.ai", "key", ["region", "key"]),
    regions: zaiRegions(false),
    name: "Z.ai (GLM)",
    mark: { agent: "zai" },
    baseUrl: "https://api.z.ai/api/paas/v4",
    keyUrl: "https://z.ai/manage-apikey/apikey-list",
    docsUrl: "https://docs.z.ai/guides/overview/quick-start",
  }),
  endpoint({
    id: "qwen",
    dialog: dialog("qwen", "Qwen", "key", ["region", "key"]),
    regions: [
      region(
        "singapore",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key",
      ),
      region(
        "virginia",
        "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
        "https://modelstudio.console.alibabacloud.com/us-east-1/settings/api-key",
      ),
      region(
        "beijing",
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://bailian.console.aliyun.com/?tab=model#/api-key",
      ),
    ],
    name: "Alibaba Qwen (DashScope)",
    mark: { agent: "qwen" },
    baseUrl: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    keyUrl: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key",
    docsUrl: "https://docs.modelstudio.console.alibabacloud.com/en/model-studio/base-url",
  }),
  endpoint({
    id: "minimax",
    dialog: dialog("minimax", "MiniMax API", "key", ["region", "key"]),
    regions: minimaxRegions(false),
    name: "MiniMax",
    mark: { agent: "minimax" },
    baseUrl: "https://api.minimax.io/v1",
    keyUrl: "https://platform.minimax.io/console/keys",
    docsUrl: "https://platform.minimax.io/docs/api-reference/text-openai-api",
  }),
  endpoint({
    id: "baseten",
    dialog: dialog("baseten", "Baseten", "key", ["key"]),
    name: "Baseten",
    mark: { agent: "baseten" },
    baseUrl: "https://inference.baseten.co/v1",
    keyUrl: "https://app.baseten.co/settings/api_keys",
    docsUrl: "https://docs.baseten.co/inference/model-apis/overview",
  }),
  endpoint({
    id: "nvidia",
    dialog: dialog("nvidia", "NVIDIA", "key", ["key"]),
    name: "NVIDIA",
    mark: { agent: "nvidia" },
    baseUrl: "https://integrate.api.nvidia.com/v1",
    keyUrl: "https://build.nvidia.com/meta/llama-3_1-8b-instruct",
    docsUrl: "https://docs.api.nvidia.com/nim/docs/api-quickstart",
  }),
  // Hugging Face OAuth requires an app registered by the team.
  endpoint({
    id: "hugging-face",
    dialog: dialog("hugging-face", "Hugging Face", "key", ["key"]),
    name: "Hugging Face",
    mark: { agent: "huggingface" },
    baseUrl: "https://router.huggingface.co/v1",
    keyUrl: "https://huggingface.co/settings/tokens",
    docsUrl: "https://huggingface.co/docs/inference-providers/index",
  }),
  endpoint({
    id: "meta",
    dialog: dialog("meta", "Meta Model API", "key", ["key"], { title: "plain" }),
    name: "Meta Model API",
    baseUrl: "https://api.meta.ai/v1",
    keyUrl: "https://dev.meta.ai",
    docsUrl: "https://dev.meta.ai/docs/overview",
    mark: { agent: "meta" },
  }),
  {
    id: "openrouter",
    dialog: dialog("openrouter", "OpenRouter", "key", ["key"]),
    name: "OpenRouter",
    group: "gateways",
    kind: "api-key",
    baseUrl: "https://openrouter.ai/api/v1",
    keyUrl: "https://openrouter.ai/keys",
    docsUrl: "https://openrouter.ai/docs/quickstart",
    mark: { agent: "openrouter" },
    families: ["claude", "codex"],
    cloud: false,
  },
  endpoint({
    id: "vercel",
    dialog: dialog("vercel", "Vercel AI Gateway", "key", ["key"], { title: "plain" }),
    name: "Vercel AI Gateway",
    group: "gateways",
    mark: { agent: "vercel" },
    baseUrl: "https://ai-gateway.vercel.sh/v1",
    keyUrl: "https://vercel.com/d?title=AI+Gateway+API+Keys&to=%2F%5Bteam%5D%2F~%2Fai-gateway%2Fapi-keys",
    docsUrl: "https://vercel.com/docs/ai-gateway/openai-compat",
  }),
  // Vercel sign-in requires a registered app. A scoped Token Pass key stops at its included credit.
  endpoint({
    id: "vercel-token-pass",
    dialog: dialog("vercel-token-pass", "Vercel Token Pass", "key", ["key"]),
    name: "Vercel Token Pass",
    group: "gateways",
    mark: { agent: "vercel" },
    baseUrl: "https://ai-gateway.vercel.sh/v1",
    keyUrl: "https://vercel.com/d?title=Token+Pass&to=%2F%5Bteam%5D%2F~%2Fai-gateway%2Ftoken-pass",
    docsUrl: "https://vercel.com/docs/ai-gateway/token-pass",
  }),
  endpoint({
    id: "cloudflare",
    dialog: dialog("cloudflare", "Cloudflare AI Gateway", "key", ["gateway", "key", "models"]),
    name: "Cloudflare AI Gateway",
    group: "gateways",
    mark: { agent: "cloudflare" },
    baseUrl: "https://gateway.ai.cloudflare.com/v1/{ACCOUNT_ID}/{GATEWAY_ID}/compat",
    keyUrl: "https://dash.cloudflare.com/profile/api-tokens",
    docsUrl: "https://developers.cloudflare.com/ai-gateway/usage/rest-api/",
  }),
  endpoint({
    id: "bedrock",
    dialog: dialog("bedrock", "Amazon Bedrock", "key", ["region", "key"], { title: "plain" }),
    regions: bedrockRegions,
    name: "Amazon Bedrock",
    group: "gateways",
    baseUrl: "https://bedrock-mantle.us-east-1.api.aws/v1",
    keyUrl: "https://console.aws.amazon.com/bedrock/",
    docsUrl: "https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions-mantle.html",
    mark: { agent: "bedrock" },
  }),
  endpoint({
    id: "azure",
    dialog: dialog("azure", "Azure OpenAI", "key", ["url", "key", "deployments"], {
      title: "plain",
    }),
    name: "Azure OpenAI",
    group: "gateways",
    baseUrl: null,
    keyUrl: "https://ai.azure.com/",
    docsUrl: "https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle",
    mark: { agent: "azure" },
    aliases: ["openai.azure.com", "cognitiveservices.azure.com", "services.ai.azure.com"],
    urlHint: "https://<resource>.openai.azure.com/openai/v1",
    deploymentName: true,
  }),
  endpoint({
    id: "ollama",
    dialog: dialog("ollama", "Ollama", "key", ["name", "url", "key", "models"], { title: "plain" }),
    name: "Ollama",
    group: "local",
    mark: { agent: "ollama" },
    baseUrl: "http://localhost:11434/v1",
    keyUrl: null,
    docsUrl: "https://docs.ollama.com/api/openai-compatibility",
  }),
  endpoint({
    id: "lm-studio",
    dialog: dialog("lm-studio", "LM Studio", "key", ["name", "url", "key", "models"], {
      title: "plain",
    }),
    name: "LM Studio",
    group: "local",
    mark: { agent: "lmstudio" },
    baseUrl: "http://localhost:1234/v1",
    keyUrl: null,
    docsUrl: "https://lmstudio.ai/docs/developer/openai-compat",
  }),
  endpoint({
    id: "endpoint",
    dialog: dialog("endpoint", "", "key", ["name", "url", "key", "models"], { title: "custom" }),
    name: "Custom endpoint",
    group: "local",
    mark: ENDPOINT_MARK,
    baseUrl: null,
    keyUrl: null,
    docsUrl: null,
  }),
];

export function providerDialogTitle(provider: CatalogProvider): string {
  const { title, titleName } = provider.dialog;
  return titleName ? t(title, titleName) : t(title);
}

export function regionForUrl(provider: CatalogProvider, baseUrl: string): ProviderRegion | undefined {
  const normalize = (url: string) => url.replace(/\/+$/, "");
  return provider.regions?.find(({ baseUrl: regionUrl, legacyBaseUrl }) =>
    [regionUrl, legacyBaseUrl].some((value) => value && normalize(value) === normalize(baseUrl)),
  );
}

export function providerName(provider: CatalogProvider): string {
  return provider.id === "endpoint" ? t("settingsWindow.models.endpoint.title") : provider.name;
}

export function providerGroupName(group: ProviderGroup): string {
  switch (group) {
    case "subscriptions":
      return t("settingsWindow.models.catalog.subscriptions");
    case "codingPlans":
      return t("settingsWindow.models.catalog.codingPlans");
    case "keys":
      return t("settingsWindow.models.catalog.apiKeys");
    case "gateways":
      return t("settingsWindow.models.catalog.gateways");
    case "local":
      return t("settingsWindow.models.catalog.local");
  }
}

export function providerById(id: string): CatalogProvider | undefined {
  return providerCatalog.find((provider) => provider.id === id);
}

export const azureResource = (host: string) =>
  /^([^.]+)\.(?:openai\.azure\.com|cognitiveservices\.azure\.com|services\.ai\.azure\.com)$/.exec(host)?.[1];

export const bedrockRegion = (host: string) => /^bedrock-mantle\.([a-z0-9-]+)\.api\.aws$/.exec(host)?.[1];

/** Older profiles have only a URL. Match regional hosts and fixed catalog URLs. */
export function endpointPresetId(endpoint: { kind: string; baseUrl: string; preset?: string }): string {
  if (endpoint.kind !== "openai-endpoint") return "endpoint";
  if (endpoint.preset && providerById(endpoint.preset)?.kind === "openai-endpoint") return endpoint.preset;
  if (!URL.canParse(endpoint.baseUrl)) return "endpoint";
  const url = new URL(endpoint.baseUrl);
  if (azureResource(url.hostname)) return "azure";
  if (bedrockRegion(url.hostname)) return "bedrock";
  if (url.hostname === "api.llama.com") return "meta";
  const base = (value: string) => value.replace(/\/+$/, "");
  return (
    providerCatalog.find(
      (provider) =>
        provider.kind === "openai-endpoint" &&
        provider.baseUrl &&
        (base(provider.baseUrl) === base(url.href) ||
          regionForUrl(provider, url.href) ||
          (provider.id === "cloudflare" &&
            /^(?:https:\/\/api\.cloudflare\.com\/client\/v4\/accounts\/[a-f0-9]{32}\/ai\/v1|https:\/\/gateway\.ai\.cloudflare\.com\/v1\/[a-f0-9]{32}\/[a-z0-9_-]+\/compat)$/i.test(
              base(url.href),
            ))),
    )?.id ?? "endpoint"
  );
}

export function providerForFamily(family: string): CatalogProvider | undefined {
  return providerById(family) ?? providerCatalog.find((provider) => provider.aliases?.includes(family));
}

export function cloudProviderForFamily(family: string): string | undefined {
  if (family === "codex") return "chatgpt";
  if (["grok", "grok-cli", "grok-build"].includes(family)) return "xai";
  const provider = providerForFamily(family);
  return provider?.cloud ? provider.id : undefined;
}

/// Search-only names: a big lab's company name finds its products and a product finds its lab ("openai" finds
/// ChatGPT, "claude" finds the Anthropic key). Not aliases: those also resolve a model family to its provider.
const LAB_SEARCH_TERMS: Readonly<Record<string, readonly string[]>> = {
  chatgpt: ["openai", "codex"],
  "codex-login": ["openai", "chatgpt"],
  openai: ["chatgpt", "codex", "gpt"],
  claude: ["anthropic"],
  "claude-login": ["anthropic"],
  anthropic: ["claude"],
  google: ["gemini"],
  "vertex-express": ["google", "gemini"],
  "gemini-login": ["google"],
  grok: ["xai"],
  xai: ["grok", "supergrok"],
  copilot: ["github", "microsoft"],
  azure: ["microsoft"],
  bedrock: ["amazon", "aws"],
  meta: ["llama", "facebook"],
  moonshot: ["kimi", "moonshot"],
  "kimi-code": ["moonshot"],
  zai: ["zhipu", "glm"],
  "glm-coding-plan": ["zhipu", "z.ai"],
  qwen: ["alibaba"],
};

export function searchProviders(query: string): CatalogProvider[] {
  const terms = query.trim().toLowerCase().split(/\s+/);
  return providerCatalog.filter((provider) => {
    const host = provider.baseUrl ? new URL(provider.baseUrl).hostname : "";
    const search = [
      providerName(provider),
      provider.id,
      providerGroupName(provider.group),
      provider.group !== "subscriptions" && provider.group !== "local" ? providerGroupName("keys") : "",
      host,
      ...(provider.aliases ?? []),
      ...(LAB_SEARCH_TERMS[provider.id] ?? []),
    ]
      .join(" ")
      .toLowerCase();
    return terms.every((term) => search.includes(term));
  });
}

export function isDeviceSignIn(signIn: ModelDeviceProvider | LocalSignIn): signIn is ModelDeviceProvider {
  return (
    signIn === "chatgpt" || signIn === "grok" || signIn === "copilot" || signIn === "kimi" || signIn === "openrouter"
  );
}

export function canAddProvider(provider: CatalogProvider, cloud: boolean): boolean {
  return !provider.detectedOnly && (!cloud || provider.cloud);
}

export function providerDisabledReason(provider: CatalogProvider): string | undefined {
  return provider.disabledReason ? t(provider.disabledReason) : undefined;
}

// Example prefixes are hints. The host accepts any printable, single-word key.
const keyExamples: Readonly<Record<string, string>> = {
  anthropic: "sk-ant-",
  openai: "sk-",
  google: "AIza",
  "vertex-express": "AQ.",
  xai: "xai-",
  openrouter: "sk-or-",
  deepseek: "sk-",
  groq: "gsk_",
  fireworks: "fw_",
  cerebras: "csk-",
  "minimax-coding-plan": "sk-cp-",
  moonshot: "sk-",
  "kimi-code": "sk-kimi-",
  vercel: "vck_",
  qwen: "sk-",
  "hugging-face": "hf_",
  nvidia: "nvapi-",
};

export function providerCredentials(provider: KeyProvider | OpenAIEndpoint) {
  const prefix = keyExamples[provider.id];
  return {
    placeholder: prefix ? t("settingsWindow.models.key.example", `${prefix}…`) : undefined,
  };
}
