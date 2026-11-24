import { useRef, useState } from "react";
import { ChiefHost } from "../../home-channels/chiefEditing";
import { endpointBackend, failureText, type AddTarget, type EndpointDraft } from "../../shared/byoEndpoint";
import type { SettingsStore } from "../store";
import { userMessage } from "../../shared/userMessage";
import { useStore } from "../context";
import { SETTINGS_SENTENCES, type ModelConnection, type ModelsRun } from "../ops";
import { providerById, type CatalogProvider } from "../providerCatalog";
import { t } from "../strings";

export type SetupSelection = {
  id: string;
  target?: string;
  edit?: boolean;
  onKeyReplaced?(): void;
};

export function isCloudSubscription({ kind }: ModelConnection) {
  return (
    kind === "claude-token" ||
    kind === "chatgpt-plan" ||
    kind === "grok-plan" ||
    kind === "copilot-plan" ||
    kind === "kimi-plan"
  );
}

export function providerFamily(provider: CatalogProvider | undefined) {
  return provider?.families[0];
}

export function tokenTimeRemaining(connection: ModelConnection, now: number): number {
  return connection.expiresAt ? connection.expiresAt * 1000 - now : Infinity;
}

export function modelEndpointBackend(
  draft: EndpointDraft,
  target: AddTarget,
  { revision, preset, servesCloud }: { revision?: string; preset?: string; servesCloud?: boolean },
) {
  return {
    ...endpointBackend(draft, target),
    ...(preset ? { preset } : {}),
    ...(revision ? { edit: revision } : {}),
    ...(servesCloud === undefined ? {} : { servesCloud }),
  };
}

/** The brand mark a connection shows (agentBrands.generated.ts names). */
export function markOf(connection: Pick<ModelConnection, "kind" | "provider">): string {
  if (connection.kind === "claude-login" || connection.kind === "claude-token") return "claude";
  if (connection.kind === "codex-login" || connection.kind === "chatgpt-plan") return "openai";
  const mark = providerById(connection.provider)?.mark;
  return mark && "agent" in mark ? mark.agent : connection.provider;
}

/** A ChatGPT sign-in's failure code in plain words. */
export function chatgptErrorText(code: string): string {
  if (code === "access_denied") return t("settingsWindow.models.chatgpt.errorDenied");
  if (code === "expired_token") return t("settingsWindow.models.chatgpt.deviceExpired");
  if (code === "network") return t("settingsWindow.models.chatgpt.deviceNetwork");
  if (code === "already_signed_in") return t("settingsWindow.models.chatgpt.deviceAlreadySignedIn");
  if (code === "no_chatgpt_account") return t("settingsWindow.models.chatgpt.errorNoPlan");
  return t("settingsWindow.models.chatgpt.errorOther");
}

/** `ids` with `id` moved to `to` (an index into the list). */
export function moveId(ids: string[], id: string, to: number): string[] {
  const rest = ids.filter((other) => other !== id);
  rest.splice(Math.max(0, Math.min(to, rest.length)), 0, id);
  return rest;
}

export type Run = (gesture: ModelsRun) => Promise<boolean>;

/** A card's gestures to the host: `run` sends one and resolves whether the host took it; `busy` while
 * one is out, `error` the last refusal's text (shown under the card). */
export function useModelsRun(): { busy: boolean; error: string | null; run: Run; clearError(): void } {
  const store = useStore();
  const inFlight = useRef(0);
  const latest = useRef(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run: Run = (gesture) => {
    const cancel = gesture.action === "cancelChatGPTDevice" || gesture.action === "cancelClaudeLogin";
    // A cancellation has to reach the host on its own click, including while Connect is settling.
    if (inFlight.current && !cancel) return Promise.resolve(false);
    inFlight.current += 1;
    const attempt = ++latest.current;
    setBusy(true);
    setError(null);
    return store
      .runModels(gesture)
      .then(
        (refusal) => {
          if (attempt === latest.current) setError(refusal);
          return refusal === null;
        },
        (failure: unknown) => {
          if (attempt === latest.current) setError(userMessage(failure, SETTINGS_SENTENCES));
          return false;
        },
      )
      .finally(() => {
        inFlight.current -= 1;
        if (!inFlight.current) setBusy(false);
      });
  };
  return { busy, error, run, clearError: () => setError(null) };
}

/** Edits endpoint metadata through the same revision-checked owner used by the endpoint form. */
export async function updateEndpointCloud(store: SettingsStore, connection: ModelConnection): Promise<string | null> {
  const endpoint = connection.endpoint;
  if (!endpoint) return null;
  try {
    await new ChiefHost(store.chiefCalls).addBackend(
      modelEndpointBackend(
        { ...endpoint, name: connection.label, models: endpoint.models.join(","), apiKey: "" },
        { id: connection.id, own: true, typedKey: connection.signedIn },
        { revision: endpoint.revision, servesCloud: !connection.servesCloud },
      ),
    );
    return null;
  } catch (error) {
    return failureText(error);
  } finally {
    await store.refreshModels();
  }
}
