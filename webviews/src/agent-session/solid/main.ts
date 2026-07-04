import { createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { render } from "solid-js/web";
import { activityGlyph } from "../shared/activityGlyph";
import { subscribeToAgentEvents } from "../shared/bridge";
import {
  CODEX_BUTTON_BASE,
  CODEX_BUTTON_COMPOSER,
  CODEX_BUTTON_COMPOSER_SM,
  CODEX_BUTTON_GHOST,
  CODEX_BUTTON_PRIMARY,
  CODEX_BUTTON_UNIFORM,
  CODEX_COMPOSER_FOOTER_MULTILINE,
  CODEX_COMPOSER_FRAME,
  CODEX_COMPOSER_INNER,
  CODEX_COMPOSER_STACK,
  CODEX_COMPOSER_SURFACE,
} from "../shared/codexClassNames";
import { insertComposerToken } from "../shared/composerTokens";
import { isComposingEnter } from "../shared/keyboard";
import { renderMarkdownHTML, renderPlainTextHTML } from "../shared/markdown";
import { codexModelLabel, providerBadgeLabel } from "../shared/providerDisplay";
import {
  formatRateLimitPercent,
  formatRateLimitReset,
  formatRateLimitWindow,
  normalizeRateLimitRow,
} from "../shared/rateLimits";
import {
  initialState,
  autoStartProvider,
  canSelectProvider,
  canStartProvider,
  canStopProvider,
  loadInitialData,
  reduceSession,
  sendInput,
  selectProvider,
  startProvider,
  statusLabel,
  stopProvider,
  type Action,
  type SessionState,
  type TranscriptEntry,
} from "../shared/sessionModel";
import { applyCodexDocumentMetadata } from "../shared/theme";
import type { AgentSessionRateLimitRow, ProviderId } from "../shared/types";

function App() {
  const [state, setState] = createSignal<SessionState>(initialState("solid"));
  const dispatch = (action: Action) => setState((current) => reduceSession(current, action));

  void loadInitialData(dispatch);
  const unsubscribe = subscribeToAgentEvents((event) => dispatch({ type: "event", event }));
  onCleanup(unsubscribe);

  createEffect(() => {
    document.documentElement.dataset.status = state().status;
  });
  const autoStartState = createMemo(() => pickAutoStartState(state()), pickAutoStartState(state()), {
    equals: autoStartStateEquals,
  });
  createEffect(() => {
    void autoStartProvider(autoStartState(), dispatch);
  });

  return SessionSurface({ state, dispatch, renderer: "Solid" });
}

function pickAutoStartState(state: SessionState): SessionState {
  return {
    context: state.context,
    providers: state.providers,
    selectedProviderId: state.selectedProviderId,
    runningSessionId: state.runningSessionId,
    status: state.status,
    input: "",
    log: [],
    transcript: [],
    autoStartAttemptedProviderIds: state.autoStartAttemptedProviderIds,
    seenSessionIds: state.seenSessionIds,
    requestedStopSessionId: state.requestedStopSessionId,
  };
}

function autoStartStateEquals(previous: SessionState, next: SessionState): boolean {
  return (
    previous.context === next.context &&
    previous.providers === next.providers &&
    previous.selectedProviderId === next.selectedProviderId &&
    previous.runningSessionId === next.runningSessionId &&
    previous.status === next.status &&
    previous.autoStartAttemptedProviderIds === next.autoStartAttemptedProviderIds &&
    previous.seenSessionIds === next.seenSessionIds &&
    previous.requestedStopSessionId === next.requestedStopSessionId
  );
}

function SessionSurface({
  state,
  dispatch,
  renderer,
}: {
  state: () => SessionState;
  dispatch: (action: Action) => void;
  renderer: string;
}) {
  const provider = () => state().providers.find((item) => item.id === state().selectedProviderId);
  const canStart = () => canStartProvider(state());
  const canStop = () => canStopProvider(state());
  const canSend = () => state().status === "running" && state().input.length > 0;
  const [isRateLimitOpen, setIsRateLimitOpen] = createSignal(false);
  const root = document.createElement("section");
  root.className = "agent-shell";
  root.dataset.codexWindowType = "electron";

  const thread = document.createElement("div");
  thread.className = "agent-thread";
  root.append(thread);
  const transcriptRows = new Map<string, HTMLDivElement>();
  const renderedTranscriptEntries = new Map<string, TranscriptEntry>();
  createEffect(() => {
    const entries = state().transcript;
    thread.toggleAttribute("data-empty", entries.length === 0);
    const liveIds = new Set(entries.map((entry) => entry.id));
    for (const [id, row] of transcriptRows) {
      if (!liveIds.has(id)) {
        row.remove();
        transcriptRows.delete(id);
        renderedTranscriptEntries.delete(id);
      }
    }
    entries.forEach((entry, index) => {
      let row = transcriptRows.get(entry.id);
      if (!row) {
        row = transcriptTurnElement(entry);
        transcriptRows.set(entry.id, row);
      }
      if (renderedTranscriptEntries.get(entry.id) !== entry) {
        updateTranscriptTurn(row, entry);
        renderedTranscriptEntries.set(entry.id, entry);
      }
      const current = thread.children.item(index);
      if (current !== row) {
        thread.insertBefore(row, current);
      }
    });
    while (thread.children.length > entries.length) {
      thread.lastElementChild?.remove();
    }
  });

  const composerStack = document.createElement("div");
  composerStack.className = CODEX_COMPOSER_STACK;
  root.append(composerStack);

  const form = document.createElement("form");
  form.className = "w-full min-w-0";
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void sendInput(state(), dispatch);
  });
  composerStack.append(form);

  const composerFrame = document.createElement("div");
  composerFrame.className = CODEX_COMPOSER_FRAME;
  form.append(composerFrame);

  const composerSurface = document.createElement("div");
  composerSurface.className = `${CODEX_COMPOSER_SURFACE} overflow-y-auto rounded-3xl`;
  composerFrame.append(composerSurface);

  const composerInner = document.createElement("div");
  composerInner.className = CODEX_COMPOSER_INNER;
  composerSurface.append(composerInner);

  const composerBody = document.createElement("div");
  composerBody.className = "mb-1 flex-grow overflow-y-auto px-3";
  composerInner.append(composerBody);

  const textarea = document.createElement("textarea");
  textarea.className = "prompt-input text-base";
  textarea.addEventListener("input", () => dispatch({ type: "setInput", input: textarea.value }));
  textarea.addEventListener("keydown", (event) => {
    if (isComposingEnter(event)) {
      return;
    }
    if (event.key !== "Enter") {
      return;
    }
    if (event.shiftKey || event.altKey) {
      return;
    }
    event.preventDefault();
    void sendInput(state(), dispatch);
  });
  composerBody.append(textarea);
  const insertToken = (token: "@" | "$") => {
    const insertion = insertComposerToken({
      text: state().input,
      selectionStart: textarea.selectionStart ?? state().input.length,
      selectionEnd: textarea.selectionEnd ?? state().input.length,
      token,
    });
    dispatch({ type: "setInput", input: insertion.text });
    queueMicrotask(() => {
      textarea.focus();
      textarea.setSelectionRange(insertion.cursor, insertion.cursor);
    });
  };
  createEffect(() => {
    textarea.placeholder = state().context?.copy.promptPlaceholder ?? "";
    textarea.setAttribute("aria-label", state().context?.copy.promptPlaceholder ?? "");
    if (textarea.value !== state().input) {
      textarea.value = state().input;
    }
  });

  const composerFooter = document.createElement("div");
  composerFooter.className = CODEX_COMPOSER_FOOTER_MULTILINE;
  composerInner.append(composerFooter);

  const leftRail = document.createElement("div");
  leftRail.className = "codex-left-rail";
  composerFooter.append(leftRail);

  const modelPicker = document.createElement("label");
  modelPicker.className =
    `model-picker ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} max-w-40 min-w-0 rounded-full`;
  const modelIcon = document.createElement("span");
  modelIcon.className = "model-icon";
  modelIcon.setAttribute("aria-hidden", "true");
  const modelLabel = document.createElement("span");
  modelLabel.className = "model-label";
  const modelChevron = document.createElement("span");
  modelChevron.className = "model-chevron";
  modelChevron.setAttribute("aria-hidden", "true");
  modelChevron.textContent = "⌄";
  modelPicker.append(modelIcon, modelLabel, modelChevron);
  leftRail.append(modelPicker);

  const select = document.createElement("select");
  select.className = "provider-select";
  select.addEventListener("change", () => {
    selectProvider(select.value as ProviderId, state(), dispatch);
  });
  modelPicker.append(select);

  const composerSeparator = document.createElement("span");
  composerSeparator.className = "composer-separator";
  composerSeparator.setAttribute("aria-hidden", "true");
  leftRail.append(
    composerSeparator,
    codexIconButton("plus", "+"),
    codexIconButton("mention", "@", () => insertToken("@")),
    codexIconButton("skill", "$", () => insertToken("$")),
  );

  createEffect(() => {
    select.replaceChildren();
    for (const item of state().providers) {
      const option = document.createElement("option");
      option.value = item.id;
      option.textContent = item.displayName;
      select.append(option);
    }
    select.value = state().selectedProviderId;
    select.disabled = !canSelectProvider(state());
    select.setAttribute("aria-label", state().context?.copy.provider ?? "");
    const selectedProvider = provider();
    modelIcon.textContent = selectedProvider ? providerBadgeLabel(selectedProvider) : "C";
    modelLabel.textContent = codexModelLabel(selectedProvider);
  });

  const controlsRight = document.createElement("div");
  controlsRight.className = "codex-right-rail";
  composerFooter.append(controlsRight);

  const start = document.createElement("button");
  start.className = `codex-action codex-start ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} rounded-full`;
  start.type = "button";
  start.addEventListener("click", () => void startProvider(state(), dispatch));
  controlsRight.append(start);
  createEffect(() => {
    start.textContent = state().context?.copy.start ?? "Start";
    const currentProvider = provider();
    const autoStartAlreadyAttempted = currentProvider
      ? state().autoStartAttemptedProviderIds.includes(currentProvider.id)
      : false;
    const showStart = canStart() && (currentProvider?.autoStart !== true || autoStartAlreadyAttempted);
    start.hidden = !showStart;
    start.disabled = !showStart;
  });

  const stop = document.createElement("button");
  stop.className =
    `codex-action codex-circle-action ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`;
  stop.type = "button";
  stop.setAttribute("aria-label", "Stop");
  stop.addEventListener("click", () => void stopProvider(state(), dispatch));
  stop.append(stopIcon());
  controlsRight.append(stop);
  createEffect(() => {
    stop.setAttribute("aria-label", state().context?.copy.stop ?? "Stop");
    const showStop = canStop();
    stop.hidden = !showStop;
    stop.disabled = !showStop;
  });

  const mic = document.createElement("button");
  mic.className =
    `codex-action codex-mic ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`;
  mic.type = "button";
  mic.disabled = true;
  mic.textContent = "♩";
  controlsRight.append(mic);
  createEffect(() => {
    mic.setAttribute("aria-label", state().context?.copy.voiceInput ?? "");
  });

  const send = document.createElement("button");
  send.className =
    `codex-action send-button ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_PRIMARY} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`;
  send.type = "submit";
  send.append(sendIcon());
  controlsRight.append(send);
  createEffect(() => {
    send.disabled = !canSend();
    send.setAttribute("aria-label", state().context?.copy.send ?? "Send");
  });

  const rateLine = document.createElement("div");
  rateLine.className = "rate-line codex-rate-limit-summary";
  rateLine.setAttribute("role", "status");
  rateLine.addEventListener("focusout", (event) => {
    const nextTarget = event.relatedTarget;
    if (!(nextTarget instanceof Node) || !rateLine.contains(nextTarget)) {
      setIsRateLimitOpen(false);
    }
  });
  composerStack.append(rateLine);
  createEffect(() => {
    renderRateLimitFooter(
      rateLine,
      state(),
      provider()?.displayName ?? renderer,
      isRateLimitOpen(),
      () => setIsRateLimitOpen((open) => !open),
    );
  });

  return root;
}

function transcriptTurnElement(entry: TranscriptEntry): HTMLDivElement {
  const row = document.createElement("div");
  if (entry.role === "user") {
    const bubble = document.createElement("div");
    bubble.className =
      "codex-user-bubble bg-token-foreground/5 max-w-[77%] min-w-0 overflow-hidden break-words rounded-2xl px-3 py-2 [&_.contain-inline-size]:[contain:initial]";
    const text = document.createElement("div");
    text.className = "text-size-chat mb-px";
    bubble.append(text);
    row.append(bubble);
    return row;
  }

  const content = document.createElement("div");
  row.append(content);
  return row;
}

function updateTranscriptTurn(row: HTMLDivElement, entry: TranscriptEntry): void {
  switch (entry.role) {
    case "user": {
      row.className = "codex-user-turn group flex w-full flex-col items-end justify-end gap-1";
      const text = row.querySelector(".text-size-chat");
      (text ?? row).innerHTML = renderPlainTextHTML(entry.text);
      break;
    }
    case "assistant": {
      row.className = "codex-assistant-turn";
      const content = row.firstElementChild as HTMLDivElement | null;
      if (content) {
        if (entry.isComplete === false) {
          content.className =
            "codex-assistant-message codex-assistant-message-streaming text-size-chat leading-[calc(var(--codex-chat-font-size)+8px)]";
          content.textContent = entry.text;
        } else {
          content.className = "codex-assistant-message text-size-chat leading-[calc(var(--codex-chat-font-size)+8px)]";
          content.innerHTML = renderMarkdownHTML(entry.text);
        }
      }
      break;
    }
    case "notice": {
      row.className = `codex-notice-turn ${entry.tone ?? "warning"}`;
      const content = row.firstElementChild as HTMLDivElement | null;
      if (content) {
        content.className = "codex-notice-content text-size-chat-sm";
        content.innerHTML = renderPlainTextHTML(entry.text);
      }
      break;
    }
    case "activity": {
      row.className = `codex-tool-activity-turn ${entry.activityKind ?? "other"} ${entry.activityStatus ?? "completed"}`;
      row.replaceChildren(activityContentElement(entry));
      if (entry.output) {
        const output = document.createElement("pre");
        output.className = "codex-tool-activity-output text-size-chat-sm";
        output.innerHTML = renderPlainTextHTML(entry.output);
        row.append(output);
      }
      break;
    }
  }
}

function activityContentElement(entry: TranscriptEntry): HTMLDivElement {
  const summary = document.createElement("div");
  summary.className =
    "codex-tool-activity-summary group/collapsed-tool-activity group/summary inline-flex w-fit max-w-full cursor-interaction items-center gap-1 self-start text-left";

  const icon = document.createElement("span");
  icon.className = "codex-tool-activity-icon icon-xs shrink-0";
  icon.setAttribute("aria-hidden", "true");
  icon.textContent = activityGlyph(entry);

  const text = document.createElement("span");
  text.className =
    "codex-tool-activity-text shrink overflow-hidden [mask-image:linear-gradient(to_right,black_calc(100%_-_0.25rem),transparent)] [mask-repeat:no-repeat] pr-1";

  const action = document.createElement("span");
  action.className = "codex-tool-activity-action";
  action.innerHTML = renderPlainTextHTML(entry.text);
  text.append(action);

  if (entry.detail) {
    const detail = document.createElement("span");
    detail.className = "codex-tool-activity-detail";
    detail.innerHTML = ` ${renderPlainTextHTML(entry.detail)}`;
    text.append(detail);
  }

  summary.append(icon, text);
  return summary;
}

function renderRateLimitFooter(
  target: HTMLElement,
  state: SessionState,
  providerDisplayName: string,
  isOpen: boolean,
  toggleOpen: () => void,
): void {
  target.replaceChildren();
  target.setAttribute("aria-label", `${providerDisplayName} ${statusLabel(state)}`.trim());
  target.className = "rate-line codex-rate-limit-summary relative";
  const rows = state.context?.rateLimitRows ?? [];
  const normalizedRows = rows.map(normalizeRateLimitRow);
  target.hidden = normalizedRows.length === 0;
  if (normalizedRows.length === 0) {
    return;
  }

  const rateLimitsLabel = state.context?.copy.rateLimits ?? "Rate limits";

  const trigger = document.createElement("button");
  trigger.className = "rate-limit-trigger rate-limit-trigger-inline flex min-w-0 items-center gap-1";
  trigger.type = "button";
  trigger.setAttribute("aria-expanded", isOpen ? "true" : "false");
  trigger.addEventListener("click", toggleOpen);

  const heading = document.createElement("span");
  heading.className = "rate-line-heading";
  heading.textContent = rateLimitsLabel;

  trigger.append(heading);
  for (const row of normalizedRows) {
    const separator = document.createElement("span");
    separator.className = "rate-limit-inline-separator";
    separator.setAttribute("aria-hidden", "true");
    separator.textContent = "•";
    trigger.append(separator, rateLimitInlineSegmentElement(row, state));
  }
  target.append(trigger);

  if (isOpen) {
    const popover = document.createElement("div");
    popover.className =
      "rate-limit-popover absolute bottom-[calc(100%+6px)] left-0 z-50 flex min-w-56 flex-col gap-1 rounded-xl border border-token-border bg-token-dropdown-background/95 px-3 py-2 text-sm shadow-xl-spread backdrop-blur-sm";
    const title = document.createElement("div");
    title.className = "rate-limit-popover-title";
    title.textContent = rateLimitsLabel;
    popover.append(title);
    for (const row of rows) {
      popover.append(rateLimitRowElement(row, state));
    }
    target.append(popover);
  }
}

function rateLimitInlineSegmentElement(
  normalized: ReturnType<typeof normalizeRateLimitRow>,
  state: SessionState,
): HTMLSpanElement {
  const segment = document.createElement("span");
  segment.className = "rate-limit-inline-segment";

  const label = document.createElement("span");
  label.className = "rate-limit-window";
  const fallbackLabel = normalized.role === "primary"
    ? state.context?.copy.rateLimitPrimary ?? "Primary"
    : state.context?.copy.rateLimitSecondary ?? "Secondary";
  label.textContent = formatRateLimitWindow(normalized.windowDurationMins, fallbackLabel, {
    weekly: state.context?.copy.rateLimitWeekly ?? "Weekly",
    monthly: state.context?.copy.rateLimitMonthly ?? "Monthly",
    daysFormat: state.context?.copy.rateLimitDaysFormat ?? "",
    hoursFormat: state.context?.copy.rateLimitHoursFormat ?? "",
    minutesFormat: state.context?.copy.rateLimitMinutesFormat ?? "",
  });

  const percent = document.createElement("span");
  percent.className = "rate-limit-percent";
  percent.textContent = formatRateLimitPercent(normalized.remainingPercent);

  segment.append(label, percent);

  const resetText = formatRateLimitReset(normalized.resetsAt);
  if (resetText) {
    const reset = document.createElement("span");
    reset.className = "rate-limit-reset";
    reset.textContent = `${state.context?.copy.rateLimitResets ?? "resets"} ${resetText}`;
    segment.append(reset);
  }

  return segment;
}

function rateLimitRowElement(row: AgentSessionRateLimitRow, state: SessionState): HTMLDivElement {
  const normalized = normalizeRateLimitRow(row);
  const item = document.createElement("div");
  item.className = "rate-limit-popover-row";

  const label = document.createElement("span");
  label.className = "rate-limit-window";
  const fallbackLabel = normalized.role === "primary"
    ? state.context?.copy.rateLimitPrimary ?? "Primary"
    : state.context?.copy.rateLimitSecondary ?? "Secondary";
  label.textContent = formatRateLimitWindow(normalized.windowDurationMins, fallbackLabel, {
    weekly: state.context?.copy.rateLimitWeekly ?? "Weekly",
    monthly: state.context?.copy.rateLimitMonthly ?? "Monthly",
    daysFormat: state.context?.copy.rateLimitDaysFormat ?? "",
    hoursFormat: state.context?.copy.rateLimitHoursFormat ?? "",
    minutesFormat: state.context?.copy.rateLimitMinutesFormat ?? "",
  });

  const value = document.createElement("span");
  value.className = "rate-limit-row-value";

  const percent = document.createElement("span");
  percent.className = "rate-limit-percent";
  percent.textContent = formatRateLimitPercent(normalized.remainingPercent);

  value.append(percent);

  const resetText = formatRateLimitReset(normalized.resetsAt);
  if (resetText) {
    const reset = document.createElement("span");
    reset.className = "rate-limit-reset";
    reset.textContent = `${state.context?.copy.rateLimitResets ?? "resets"} ${resetText}`;
    value.append(reset);
  }

  item.append(label, value);
  return item;
}

function sendIcon(): SVGSVGElement {
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("width", "14");
  icon.setAttribute("height", "14");
  icon.setAttribute("viewBox", "0 0 14 14");
  icon.setAttribute("fill", "none");
  icon.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", "M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.8");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  icon.append(path);
  return icon;
}

function stopIcon(): SVGSVGElement {
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("width", "16");
  icon.setAttribute("height", "16");
  icon.setAttribute("viewBox", "0 0 16 16");
  icon.setAttribute("fill", "none");
  icon.setAttribute("aria-hidden", "true");
  const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
  rect.setAttribute("x", "4.75");
  rect.setAttribute("y", "4.75");
  rect.setAttribute("width", "6.5");
  rect.setAttribute("height", "6.5");
  rect.setAttribute("rx", "1");
  rect.setAttribute("fill", "currentColor");
  icon.append(rect);
  return icon;
}

function codexIconButton(kind: string, text: string, onClick?: () => void): HTMLButtonElement {
  const button = document.createElement("button");
  button.className =
    `codex-tool codex-tool-${kind} ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER_SM} ${CODEX_BUTTON_UNIFORM} rounded-full`;
  button.type = "button";
  if (onClick) {
    button.addEventListener("click", onClick);
  } else {
    button.disabled = true;
    button.setAttribute("aria-hidden", "true");
  }
  button.textContent = text;
  return button;
}

const root = document.getElementById("root");
if (root) {
  applyCodexDocumentMetadata();
  render(App, root);
}
