import type { DiffViewerAppearance } from "../appearance";
import type { CSSProperties, KeyboardEvent, ReactNode } from "react";
import { useMemo, useRef, useState } from "react";

type OpenChatLabelKey =
  | "accountSwitcher"
  | "addCredits"
  | "addCreditsUnavailable"
  | "approvalMode"
  | "attachContext"
  | "branchSelector"
  | "connectApps"
  | "connectAppsUnavailable"
  | "environmentSelector"
  | "headingFormat"
  | "model"
  | "modelEffort"
  | "placeholder"
  | "rateLimitSubtitleFormat"
  | "rateLimitTitle"
  | "reasoning"
  | "repoSelector"
  | "resetUsage"
  | "resetUsageUnavailable"
  | "send"
  | "submitUnavailableFormat"
  | "title"
  | "voiceInput"
  | "voiceUnavailable";

type OpenChatOption = {
  id: string;
  label: string;
  selected?: boolean;
  warning?: boolean;
};

type OpenChatSuggestion = {
  id: string;
  kind: "prompt" | "apps";
  label: string;
};

export type OpenChatConfig = {
  payload: {
    title: string;
    workspaceName: string;
    repoName: string;
    branchName: string;
    repoRoot?: string;
    appearance: DiffViewerAppearance;
    labels: Record<OpenChatLabelKey, string>;
    rateLimit: {
      resetTime: string;
    };
    models: OpenChatOption[];
    reasoningLevels: OpenChatOption[];
    approvalModes: OpenChatOption[];
    contextOptions: {
      repositories: OpenChatOption[];
      environments: OpenChatOption[];
      branches: OpenChatOption[];
    };
    suggestions: OpenChatSuggestion[];
    generatedAt: string;
  };
};

type MenuKind = "approval" | "model" | "repo" | "environment" | "branch";

const storageKeys = {
  approval: "cmux.openChat.approvalMode",
  model: "cmux.openChat.model",
  reasoning: "cmux.openChat.reasoning",
  repo: "cmux.openChat.repo",
  environment: "cmux.openChat.environment",
  branch: "cmux.openChat.branch",
};

export function OpenChatApp({ config }: { config: OpenChatConfig }) {
  const payload = config.payload;
  const label = labelResolver(payload.labels);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [input, setInput] = useState("");
  const [status, setStatus] = useState("");
  const [activeMenu, setActiveMenu] = useState<MenuKind | null>(null);
  const [approvalId, setApprovalId] = useStoredSelection(storageKeys.approval, payload.approvalModes);
  const [modelId, setModelId] = useStoredSelection(storageKeys.model, payload.models);
  const [reasoningId, setReasoningId] = useStoredSelection(storageKeys.reasoning, payload.reasoningLevels);
  const [repoId, setRepoId] = useStoredSelection(storageKeys.repo, payload.contextOptions.repositories);
  const [environmentId, setEnvironmentId] = useStoredSelection(storageKeys.environment, payload.contextOptions.environments);
  const [branchId, setBranchId] = useStoredSelection(storageKeys.branch, payload.contextOptions.branches);
  const [voiceActive, setVoiceActive] = useState(false);

  const approval = selectedOption(payload.approvalModes, approvalId);
  const model = selectedOption(payload.models, modelId);
  const reasoning = selectedOption(payload.reasoningLevels, reasoningId);
  const repo = selectedOption(payload.contextOptions.repositories, repoId);
  const environment = selectedOption(payload.contextOptions.environments, environmentId);
  const branch = selectedOption(payload.contextOptions.branches, branchId);
  const heading = formatLabel(label("headingFormat"), payload.workspaceName);
  const rateLimitSubtitle = formatLabel(label("rateLimitSubtitleFormat"), payload.rateLimit.resetTime);

  const menus = useMemo(
    () => ({
      approval: {
        label: label("approvalMode"),
        options: payload.approvalModes,
        selectedId: approvalId,
        setSelectedId: setApprovalId,
      },
      repo: {
        label: label("repoSelector"),
        options: payload.contextOptions.repositories,
        selectedId: repoId,
        setSelectedId: setRepoId,
      },
      environment: {
        label: label("environmentSelector"),
        options: payload.contextOptions.environments,
        selectedId: environmentId,
        setSelectedId: setEnvironmentId,
      },
      branch: {
        label: label("branchSelector"),
        options: payload.contextOptions.branches,
        selectedId: branchId,
        setSelectedId: setBranchId,
      },
    }),
    [
      approvalId,
      branchId,
      environmentId,
      label,
      payload.approvalModes,
      payload.contextOptions.branches,
      payload.contextOptions.environments,
      payload.contextOptions.repositories,
      repoId,
      setApprovalId,
      setBranchId,
      setEnvironmentId,
      setRepoId,
    ],
  );

  function submit(): void {
    const trimmed = input.trim();
    if (!trimmed) {
      return;
    }
    setStatus(formatLabel(label("submitUnavailableFormat"), trimmed));
    textareaRef.current?.focus();
    resizeTextArea(textareaRef.current);
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>): void {
    if (event.nativeEvent.isComposing || event.keyCode === 229) {
      return;
    }
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  }

  function selectSuggestion(suggestion: OpenChatSuggestion): void {
    if (suggestion.kind === "prompt") {
      setInput(suggestion.label);
      queueMicrotask(() => {
        textareaRef.current?.focus();
        resizeTextArea(textareaRef.current);
      });
      return;
    }
    setStatus(label("connectAppsUnavailable"));
  }

  function toggleVoice(): void {
    setVoiceActive((current) => !current);
    setStatus(label("voiceUnavailable"));
  }

  return (
    <main className="open-chat-shell">
      <div className="open-chat-accent" />
      <button
        className="open-chat-account"
        type="button"
        aria-label={label("accountSwitcher")}
        aria-expanded={activeMenu === "model"}
        onClick={() => setActiveMenu(activeMenu === "model" ? null : "model")}
      >
        <span className="open-chat-app-icon">C</span>
        <Icon name="chevron" />
      </button>

      <section className="open-chat-center" aria-label={payload.title}>
        <h1>{heading}</h1>

        <section className="open-chat-rate-card" aria-label={label("rateLimitTitle")}>
          <div className="open-chat-rate-icon" aria-hidden="true">
            <Icon name="gauge" />
          </div>
          <div className="open-chat-rate-copy">
            <strong>{label("rateLimitTitle")}</strong>
            <p>{rateLimitSubtitle}</p>
          </div>
          <div className="open-chat-rate-actions">
            <button
              type="button"
              className="open-chat-button open-chat-button-primary"
              onClick={() => setStatus(label("addCreditsUnavailable"))}
            >
              {label("addCredits")}
            </button>
            <button
              type="button"
              className="open-chat-button open-chat-button-ghost"
              onClick={() => setStatus(label("resetUsageUnavailable"))}
            >
              {label("resetUsage")}
            </button>
          </div>
        </section>

        <section className="open-chat-composer">
          <textarea
            ref={textareaRef}
            value={input}
            aria-label={label("placeholder")}
            placeholder={label("placeholder")}
            rows={3}
            onChange={(event) => {
              setInput(event.target.value);
              resizeTextArea(event.currentTarget);
            }}
            onInput={(event) => resizeTextArea(event.currentTarget)}
            onKeyDown={handleKeyDown}
          />

          <div className="open-chat-toolbar">
            <div className="open-chat-toolbar-left">
              <button
                className="open-chat-icon-button"
                type="button"
                aria-label={label("attachContext")}
                onClick={() => setActiveMenu(activeMenu === "repo" ? null : "repo")}
              >
                <Icon name="plus" />
              </button>
              <MenuButton
                active={activeMenu === "approval"}
                className="open-chat-approval-button"
                label={label("approvalMode")}
                onClick={() => setActiveMenu(activeMenu === "approval" ? null : "approval")}
              >
                {approval.warning ? <span className="open-chat-warning">!</span> : null}
                <span>{approval.label}</span>
                <Icon name="chevron" />
              </MenuButton>
            </div>

            <div className="open-chat-toolbar-right">
              <span className="open-chat-lightning" aria-hidden="true">
                <Icon name="bolt" />
              </span>
              <button
                className="open-chat-model-button"
                type="button"
                aria-label={label("modelEffort")}
                aria-expanded={activeMenu === "model"}
                onClick={() => setActiveMenu(activeMenu === "model" ? null : "model")}
              >
                <span>{model.label}</span>
                <span>{reasoning.label}</span>
                <Icon name="chevron" />
              </button>
              <button
                className={`open-chat-icon-button${voiceActive ? " open-chat-icon-button-active" : ""}`}
                type="button"
                aria-label={label("voiceInput")}
                aria-pressed={voiceActive}
                onClick={toggleVoice}
              >
                <Icon name="mic" />
              </button>
              <button
                className="open-chat-send"
                type="button"
                aria-label={label("send")}
                disabled={input.trim().length === 0}
                onClick={submit}
              >
                <Icon name="arrowUp" />
              </button>
            </div>
          </div>

          {activeMenu === "approval" ? (
            <OptionMenu
              label={menus.approval.label}
              options={menus.approval.options}
              selectedId={menus.approval.selectedId}
              onSelect={(id) => {
                menus.approval.setSelectedId(id);
                setActiveMenu(null);
              }}
            />
          ) : null}
          {activeMenu === "model" ? (
            <ModelMenu
              label={label("modelEffort")}
              modelLabel={label("model")}
              models={payload.models}
              modelId={modelId}
              reasoningLabel={label("reasoning")}
              reasoningLevels={payload.reasoningLevels}
              reasoningId={reasoningId}
              onModelSelect={(id) => {
                setModelId(id);
                setActiveMenu(null);
              }}
              onReasoningSelect={(id) => {
                setReasoningId(id);
                setActiveMenu(null);
              }}
            />
          ) : null}
        </section>

        <div className="open-chat-context-row">
          <ContextPill
            icon="folder"
            label={repo.label}
            title={label("repoSelector")}
            active={activeMenu === "repo"}
            onClick={() => setActiveMenu(activeMenu === "repo" ? null : "repo")}
          />
          <ContextPill
            icon="laptop"
            label={environment.label}
            title={label("environmentSelector")}
            active={activeMenu === "environment"}
            onClick={() => setActiveMenu(activeMenu === "environment" ? null : "environment")}
          />
          <ContextPill
            icon="branch"
            label={branch.label}
            title={label("branchSelector")}
            active={activeMenu === "branch"}
            onClick={() => setActiveMenu(activeMenu === "branch" ? null : "branch")}
          />
        </div>

        {activeMenu === "repo" || activeMenu === "environment" || activeMenu === "branch" ? (
          <div className="open-chat-context-menu">
            <OptionMenu
              label={menus[activeMenu].label}
              options={menus[activeMenu].options}
              selectedId={menus[activeMenu].selectedId}
              onSelect={(id) => {
                menus[activeMenu].setSelectedId(id);
                setActiveMenu(null);
              }}
            />
          </div>
        ) : null}

        <div className="open-chat-suggestions">
          {payload.suggestions.map((suggestion) => (
            <button
              key={suggestion.id}
              className="open-chat-suggestion"
              type="button"
              onClick={() => selectSuggestion(suggestion)}
            >
              <Icon name={suggestion.kind === "apps" ? "grid" : "bubble"} />
              <span>{suggestion.label}</span>
            </button>
          ))}
        </div>

        {status ? (
          <p className="open-chat-status" aria-live="polite">
            {status}
          </p>
        ) : null}
      </section>

      <div className="open-chat-home-indicator" aria-hidden="true" />
    </main>
  );
}

function MenuButton({
  active,
  children,
  className,
  label,
  onClick,
}: {
  active: boolean;
  children: ReactNode;
  className: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button className={className} type="button" aria-label={label} aria-expanded={active} onClick={onClick}>
      {children}
    </button>
  );
}

function OptionMenu({
  label,
  options,
  selectedId,
  onSelect,
}: {
  label: string;
  options: OpenChatOption[];
  selectedId: string;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="open-chat-menu" role="menu" aria-label={label}>
      {options.map((option) => (
        <button
          key={option.id}
          className="open-chat-menu-item"
          type="button"
          role="menuitemradio"
          aria-checked={option.id === selectedId}
          onClick={() => onSelect(option.id)}
        >
          <span>{option.label}</span>
          {option.warning ? <span className="open-chat-warning">!</span> : null}
          {option.id === selectedId ? <Icon name="check" /> : null}
        </button>
      ))}
    </div>
  );
}

function ModelMenu({
  label,
  modelLabel,
  models,
  modelId,
  reasoningLabel,
  reasoningLevels,
  reasoningId,
  onModelSelect,
  onReasoningSelect,
}: {
  label: string;
  modelLabel: string;
  models: OpenChatOption[];
  modelId: string;
  reasoningLabel: string;
  reasoningLevels: OpenChatOption[];
  reasoningId: string;
  onModelSelect: (id: string) => void;
  onReasoningSelect: (id: string) => void;
}) {
  return (
    <div className="open-chat-menu open-chat-model-menu" role="menu" aria-label={label}>
      <fieldset className="open-chat-menu-section" aria-label={modelLabel}>
        <span className="open-chat-menu-heading">{modelLabel}</span>
        {models.map((option) => (
          <button
            key={option.id}
            className="open-chat-menu-item"
            type="button"
            role="menuitemradio"
            aria-checked={option.id === modelId}
            onClick={() => onModelSelect(option.id)}
          >
            <span>{option.label}</span>
            {option.id === modelId ? <Icon name="check" /> : null}
          </button>
        ))}
      </fieldset>
      <fieldset className="open-chat-menu-section" aria-label={reasoningLabel}>
        <span className="open-chat-menu-heading">{reasoningLabel}</span>
        {reasoningLevels.map((option) => (
          <button
            key={option.id}
            className="open-chat-menu-item"
            type="button"
            role="menuitemradio"
            aria-checked={option.id === reasoningId}
            onClick={() => onReasoningSelect(option.id)}
          >
            <span>{option.label}</span>
            {option.id === reasoningId ? <Icon name="check" /> : null}
          </button>
        ))}
      </fieldset>
    </div>
  );
}

function ContextPill({
  active,
  icon,
  label,
  title,
  onClick,
}: {
  active: boolean;
  icon: IconName;
  label: string;
  title: string;
  onClick: () => void;
}) {
  return (
    <button className="open-chat-pill" type="button" title={title} aria-expanded={active} onClick={onClick}>
      <Icon name={icon} />
      <span>{label}</span>
      <Icon name="chevron" />
    </button>
  );
}

function useStoredSelection(
  key: string,
  options: OpenChatOption[],
): [string, (next: string) => void] {
  const defaultId = options.find((option) => option.selected)?.id ?? options[0]?.id ?? "";
  const [value, setValue] = useState(() => {
    const stored = safeLocalStorageGet(key);
    return stored && options.some((option) => option.id === stored) ? stored : defaultId;
  });
  return [
    value,
    (next) => {
      setValue(next);
      safeLocalStorageSet(key, next);
    },
  ];
}

function selectedOption(options: OpenChatOption[], selectedId: string): OpenChatOption {
  return options.find((option) => option.id === selectedId) ?? options.find((option) => option.selected) ?? options[0] ?? {
    id: "",
    label: "",
  };
}

function labelResolver(labels: Record<OpenChatLabelKey, string>) {
  return (key: OpenChatLabelKey): string => labels[key] || key;
}

function formatLabel(format: string, value: string): string {
  return format.replace("%@", value).replace("%s", value);
}

function resizeTextArea(textarea: HTMLTextAreaElement | null): void {
  if (!textarea) {
    return;
  }
  textarea.style.height = "auto";
  textarea.style.height = `${textarea.scrollHeight}px`;
}

function safeLocalStorageGet(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function safeLocalStorageSet(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    return;
  }
}

type IconName =
  | "arrowUp"
  | "bolt"
  | "branch"
  | "bubble"
  | "check"
  | "chevron"
  | "folder"
  | "gauge"
  | "grid"
  | "laptop"
  | "mic"
  | "plus";

function Icon({ name }: { name: IconName }) {
  const path = iconPath(name);
  const style = { "--icon-stroke": name === "bolt" ? "2.4" : "2" } as CSSProperties;
  return (
    <svg aria-hidden="true" className="open-chat-icon" viewBox="0 0 24 24" fill="none" style={style}>
      {path}
    </svg>
  );
}

function iconPath(name: IconName): ReactNode {
  switch (name) {
    case "arrowUp":
      return <><path d="M12 19V5" /><path d="m5 12 7-7 7 7" /></>;
    case "bolt":
      return <path d="M13 2 4 14h7l-1 8 9-13h-7l1-7Z" />;
    case "branch":
      return <><path d="M6 3v12" /><path d="M18 9a6 6 0 0 1-6 6H6" /><circle cx="6" cy="18" r="3" /><circle cx="6" cy="3" r="2" /><circle cx="18" cy="9" r="3" /></>;
    case "bubble":
      return <><path d="M21 11.5a8.5 8.5 0 0 1-12.7 7.4L3 20l1.1-5.1A8.5 8.5 0 1 1 21 11.5Z" /></>;
    case "check":
      return <path d="m5 12 4 4L19 6" />;
    case "chevron":
      return <path d="m7 10 5 5 5-5" />;
    case "folder":
      return <path d="M3 6.5A2.5 2.5 0 0 1 5.5 4H10l2 2h6.5A2.5 2.5 0 0 1 21 8.5v8A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5v-10Z" />;
    case "gauge":
      return <><path d="M4 14a8 8 0 1 1 16 0" /><path d="M12 14l4-5" /><path d="M8 18h8" /><circle cx="12" cy="14" r="1.5" /></>;
    case "grid":
      return <><rect x="4" y="4" width="6" height="6" rx="1.4" /><rect x="14" y="4" width="6" height="6" rx="1.4" /><rect x="4" y="14" width="6" height="6" rx="1.4" /><rect x="14" y="14" width="6" height="6" rx="1.4" /></>;
    case "laptop":
      return <><rect x="5" y="5" width="14" height="10" rx="1.5" /><path d="M3 19h18" /></>;
    case "mic":
      return <><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0" /><path d="M12 18v3" /></>;
    case "plus":
      return <><path d="M12 5v14" /><path d="M5 12h14" /></>;
  }
}
