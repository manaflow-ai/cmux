// l10n-allow-file: gallery fixtures (provider URLs and a provider's own refusal text), not shipped UI.
// The dictation engine's key card (Settings > Agent Chat > Message Box, under the dictation rows) in
// each of its states: on this Mac, a keyless server, a key to paste (required and optional), a custom
// engine without its URL, a saved key, a check running, connected, a refused key, a provider's own
// refusal, and a state the app could not read. Each draws inside a Settings card, as on the page.
import { componentEntry } from "../../../gallery/format";
import type { DictationState } from "../ops";
import type { DictationStatus } from "./DictationProviderCard";

type Shape = {
  engine: string;
  url?: string;
  hasKey?: boolean;
  status?: DictationStatus;
  unavailable?: boolean;
};

type Props = { shape: Shape };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { DictationProviderRows, DictationUnavailableRow } = await import("./DictationProviderCard");
  const { mockDictationState } = await import("../mockDictation");
  return function DictationProviderStates({ shape }: Props) {
    const state: DictationState = mockDictationState(shape.engine, { url: shape.url, hasKey: shape.hasKey });
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group">
          <div className="rows">
            {shape.unavailable ? (
              <DictationUnavailableRow onRetry={() => {}} />
            ) : (
              <DictationProviderRows
                state={state}
                status={shape.status ?? { kind: "idle" }}
                busy={shape.status?.kind === "checking"}
                onCheck={() => {}}
                onSave={async () => false}
                onRemove={() => {}}
              />
            )}
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.dictation-provider",
  title: "Dictation engine key card",
  area: "Settings",
  height: 220,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/DictationProviderCard.tsx"],
  load,
  styles: () => import("../page.css"),
  variants: {
    "on-device": {
      note: "On This Mac (the default): one line, nothing to set.",
      props: { shape: { engine: "onDevice" } },
    },
    keyless: {
      note: "whisper.cpp: where recordings go, and Check Connection.",
      props: { shape: { engine: "whisperCpp" } },
    },
    "key-required": {
      note: "OpenAI with no key saved: the password field and Save.",
      props: { shape: { engine: "openai" } },
    },
    "key-optional": {
      note: "A local server: the key is optional, and Check works without one.",
      props: { shape: { engine: "localServer" } },
    },
    "needs-url": { note: "Custom with no URL yet: the key waits for the URL.", props: { shape: { engine: "custom" } } },
    "key-saved": {
      note: "A saved key: Key saved in Keychain, Replace and Remove; the key is never shown.",
      props: { shape: { engine: "groq", hasKey: true } },
    },
    checking: {
      note: "Check Connection running: the status line says so, the button waits.",
      props: { shape: { engine: "openai", hasKey: true, status: { kind: "checking" } } },
    },
    connected: {
      note: "The check (or the one after Save) passed.",
      props: { shape: { engine: "openai", hasKey: true, status: { kind: "connected" } } },
    },
    "key-invalid": {
      note: "The provider refused the key: what to do next.",
      props: {
        shape: {
          engine: "openai",
          hasKey: true,
          status: { kind: "failed", error: { code: "key_invalid", detail: "" } },
        },
      },
    },
    rejected: {
      note: "The provider refused the request, with its own words.",
      props: {
        shape: {
          engine: "custom",
          url: "https://transcribe.example.com/v1",
          hasKey: true,
          status: { kind: "failed", error: { code: "rejected", detail: "model 'whisper-9' does not exist" } },
        },
      },
    },
    unavailable: {
      note: "The app could not reach cmux's background service: a plain line and Try Again.",
      props: { shape: { engine: "onDevice", unavailable: true } },
    },
  },
});
