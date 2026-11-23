// l10n-allow-file: mock fixtures (provider names and URLs as acpmux answers them), not shipped UI.
// The dictation engine's state as acpmux's `_acpmux/voice/state` answers it (crate cmux-voice's
// catalog), for the mock provider, the card's tests and its gallery. Not shipped.
import type { DictationProvider, DictationState } from "./ops";

/** The catalog, as the contract lists it (provider names are product names, never translated). */
export const MOCK_DICTATION_PROVIDERS: DictationProvider[] = [
  {
    id: "onDevice",
    label: "On This Mac",
    kind: "local",
    wire: "builtin",
    key: "none",
    defaultUrl: "",
    defaultModel: "",
  },
  {
    id: "openai",
    label: "OpenAI",
    kind: "cloud",
    wire: "openaiTranscriptions",
    key: "required",
    defaultUrl: "https://api.openai.com/v1",
    defaultModel: "gpt-4o-mini-transcribe",
  },
  {
    id: "groq",
    label: "Groq",
    kind: "cloud",
    wire: "openaiTranscriptions",
    key: "required",
    defaultUrl: "https://api.groq.com/openai/v1",
    defaultModel: "whisper-large-v3-turbo",
  },
  {
    id: "localServer",
    label: "Local Server",
    kind: "local",
    wire: "openaiTranscriptions",
    key: "optional",
    defaultUrl: "http://127.0.0.1:8000/v1",
    defaultModel: "",
  },
  {
    id: "whisperCpp",
    label: "whisper.cpp Server",
    kind: "local",
    wire: "whisperCppInference",
    key: "none",
    defaultUrl: "http://127.0.0.1:8080",
    defaultModel: "",
  },
  {
    id: "custom",
    label: "Custom Endpoint",
    kind: "cloud",
    wire: "openaiTranscriptions",
    key: "optional",
    defaultUrl: "",
    defaultModel: "",
  },
];

/** `engine`'s state with its defaults, as acpmux resolves it; `url` overrides the default base URL. */
export function mockDictationState(
  engine: string,
  options: { url?: string; model?: string; hasKey?: boolean } = {},
): DictationState {
  const provider = MOCK_DICTATION_PROVIDERS.find((entry) => entry.id === engine) ?? MOCK_DICTATION_PROVIDERS[0]!;
  const url = options.url ?? provider.defaultUrl;
  let origin: string | null = null;
  try {
    origin = url ? new URL(url).origin.toLowerCase() : null;
  } catch {
    origin = null;
  }
  return {
    engine: provider.id,
    label: provider.label,
    kind: provider.kind,
    wire: provider.wire,
    key: provider.key,
    url,
    model: options.model ?? provider.defaultModel,
    keyAccount: provider.key !== "none" && origin ? `${provider.id}@${origin}` : null,
    keyService: "cmux-voice-key",
    hasKey: provider.key !== "none" && (options.hasKey ?? false),
    providers: MOCK_DICTATION_PROVIDERS,
  };
}
