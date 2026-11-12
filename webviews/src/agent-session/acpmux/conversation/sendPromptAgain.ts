import type { AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { isStopped, offersRetry, retryTargetIn } from "./turns";
import { retryModelSections, type RetryModel } from "./retryModelSections";

export type SendPromptAgainMenu = {
  sessionId: string;
  rowId: string;
  label: string;
  modelsLabel: string;
  moreModelsLabel: string;
  currentModel?: string;
  latestModels?: { id: string; name: string }[];
  moreModels?: { id: string; name: string }[];
};

export type SendPromptAgainState = {
  sessionId?: string;
  selectedSessionId?: string;
  drawnSessionId?: string;
  canSend: boolean;
  rows: readonly AcpmuxRow[];
  models: readonly RetryModel[];
  currentModel?: string;
  harness?: string;
  top?: readonly string[];
};

export function sendPromptAgainTarget(state: SendPromptAgainState) {
  const { sessionId, selectedSessionId, drawnSessionId, canSend, rows } = state;
  if (!canSend || !sessionId || sessionId !== selectedSessionId || sessionId !== drawnSessionId) return undefined;
  const target = retryTargetIn(rows);
  if (!target.promptId || !target.footerId) return undefined;
  const footer = rows.find((row) => row.id === target.footerId);
  if (
    !footer ||
    (footer.status !== undefined && footer.status !== "completed" && !isStopped(footer)) ||
    !offersRetry(footer) ||
    footer.retryRowId !== target.promptId
  )
    return undefined;
  return {
    sessionId,
    footerId: footer.id,
    messageId: footer.answerId ?? footer.id,
    promptId: target.promptId!,
    prompt: footer.prompt!,
  };
}

export function sendPromptAgainMenu(state: SendPromptAgainState, t: Translate): SendPromptAgainMenu | undefined {
  const target = sendPromptAgainTarget(state);
  if (!target) return undefined;
  const sections = retryModelSections(state.models, state.currentModel, state.harness, state.top);
  const models = [...sections.latest, ...sections.more];
  const current = models.find((model) => model.id === state.currentModel || model.release === state.currentModel);
  const rows = (items: readonly RetryModel[]) => items.map(({ id, name }) => ({ id, name }));
  return {
    sessionId: target.sessionId,
    rowId: target.footerId,
    label: t("turn.retryLabel"),
    modelsLabel: t("turn.retryWith"),
    moreModelsLabel: t("picker.moreModels"),
    ...(state.currentModel ? { currentModel: current?.id ?? state.currentModel } : {}),
    ...(models.length > 1 ? { latestModels: rows(sections.latest), moreModels: rows(sections.more) } : {}),
  };
}

export type SendPromptAgainRequest = { sessionId: string; rowId: string; model?: string };

export async function sendPromptAgain<Draft>(
  request: SendPromptAgainRequest,
  deps: {
    read: () => SendPromptAgainState;
    pickModel: (model: string, sessionId: string, currentModel?: string) => Promise<boolean>;
    restore: (rowId: string, prompt: string) => Promise<Draft>;
    send: (draft: Draft, sessionId: string) => Promise<unknown>;
  },
): Promise<boolean> {
  const initial = deps.read();
  const target = sendPromptAgainTarget(initial);
  const initialSections = retryModelSections(initial.models, initial.currentModel, initial.harness, initial.top);
  const selectedModel = [...initialSections.latest, ...initialSections.more].find(
    (model) => model.id === request.model,
  );
  if (request.model !== undefined && !selectedModel) return false;
  const selectedIdentity = selectedModel ? (selectedModel.release ?? selectedModel.id) : undefined;
  const matches = (requireSelectedModel = false) => {
    const state = deps.read();
    const current = sendPromptAgainTarget(state);
    if (
      !current ||
      current.sessionId !== request.sessionId ||
      current.footerId !== request.rowId ||
      current.promptId !== target?.promptId ||
      current.prompt !== target.prompt
    )
      return false;
    if (request.model !== undefined) {
      const sections = retryModelSections(state.models, state.currentModel, state.harness, state.top);
      const offered = [...sections.latest, ...sections.more].some(
        (model) => (model.release ?? model.id) === selectedIdentity,
      );
      if (!offered || !requireSelectedModel) return offered;
      const currentModel = state.models.find(
        (model) => model.id === state.currentModel || model.release === state.currentModel,
      );
      return (currentModel?.release ?? state.currentModel) === selectedIdentity;
    }
    return state.currentModel === initial.currentModel;
  };
  if (!target || !matches()) return false;
  if (request.model !== undefined && request.model !== initial.currentModel) {
    if (!(await deps.pickModel(request.model, target.sessionId, initial.currentModel)) || !matches(true)) return false;
  }
  const draft = await deps.restore(target.promptId, target.prompt);
  if (!matches(true)) return false;
  await deps.send(draft, target.sessionId);
  return true;
}
