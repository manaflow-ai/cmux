import { useCallback, useRef, useState, useSyncExternalStore } from "react";
import { callFeedNative, feedSnapshotStore } from "./bridge";
import { feedSourceIcons } from "./sourceIcons";
import type { CSSProperties, KeyboardEvent as ReactKeyboardEvent } from "react";
import type { FeedCopy, FeedIntegration, FeedItem, FeedQuestion } from "./types";
import "./styles.css";

type Filter = "actionable" | "activity";
export const feedActivityPageSize = 40;

function isEditable(target: EventTarget | null) {
  return target instanceof HTMLElement
    && (target.isContentEditable || ["INPUT", "SELECT", "TEXTAREA"].includes(target.tagName));
}

export function handleFeedNavigation(event: KeyboardEvent, root: HTMLElement) {
  if (event.key === "Tab" && !event.altKey && !event.ctrlKey && !event.metaKey) {
    const activeElement = document.activeElement as HTMLElement | null;
    const activeCard = activeElement?.closest<HTMLElement>(".feed-card");
    if (activeCard) {
      const cardControls = [...activeCard.querySelectorAll<HTMLElement>(
        'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
      )].filter((control) => control.tabIndex >= 0);
      if (activeElement === activeCard && cardControls.length > 0) {
        event.preventDefault();
        cardControls[event.shiftKey ? cardControls.length - 1 : 0]?.focus();
        return;
      }
      if (event.shiftKey && activeElement === cardControls[0]) {
        event.preventDefault();
        activeCard.focus({ preventScroll: true });
        return;
      }
    }
    const controls = [...root.querySelectorAll<HTMLElement>(
      'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
    )].filter((control) => control !== root && control.tabIndex >= 0);
    if (controls.length === 0) return;
    const activeIndex = controls.indexOf(document.activeElement as HTMLElement);
    const nextIndex = activeIndex < 0
      ? (event.shiftKey ? controls.length - 1 : 0)
      : (activeIndex + (event.shiftKey ? -1 : 1) + controls.length) % controls.length;
    event.preventDefault();
    controls[nextIndex]?.focus();
    return;
  }
  if (isEditable(event.target) || event.altKey || event.metaKey) return;
  const key = event.key.toLowerCase();
  const direction = !event.ctrlKey && (key === "j" || key === "arrowdown")
    ? 1
    : !event.ctrlKey && (key === "k" || key === "arrowup")
      ? -1
      : event.ctrlKey && key === "n"
        ? 1
        : event.ctrlKey && key === "p"
          ? -1
          : 0;
  const isBoundaryKey = !event.ctrlKey && (key === "home" || key === "end");
  if (direction === 0 && !isBoundaryKey) return;
  const cards = [...root.querySelectorAll<HTMLElement>(".feed-card")];
  if (cards.length === 0) return;
  const activeCard = document.activeElement?.closest<HTMLElement>(".feed-card");
  const activeIndex = activeCard ? cards.indexOf(activeCard) : -1;
  const nextIndex = key === "home"
    ? 0
    : key === "end"
      ? cards.length - 1
      : activeIndex < 0
        ? (direction > 0 ? 0 : cards.length - 1)
        : Math.max(0, Math.min(cards.length - 1, activeIndex + direction));
  event.preventDefault();
  cards[nextIndex]?.focus({ preventScroll: true });
  cards[nextIndex]?.scrollIntoView?.({ block: "nearest" });
}

function handleTabNavigation(event: ReactKeyboardEvent<HTMLDivElement>) {
  const tabs = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="tab"]')];
  const currentIndex = tabs.indexOf(document.activeElement as HTMLButtonElement);
  if (currentIndex < 0) return;
  const key = event.key;
  const nextIndex = key === "Home"
    ? 0
    : key === "End"
      ? tabs.length - 1
      : key === "ArrowLeft"
        ? (currentIndex - 1 + tabs.length) % tabs.length
        : key === "ArrowRight"
          ? (currentIndex + 1) % tabs.length
          : -1;
  if (nextIndex < 0) return;
  event.preventDefault();
  event.stopPropagation();
  tabs[nextIndex]?.focus();
  tabs[nextIndex]?.click();
}

export function createDemoFeedItems(copy: FeedCopy): FeedItem[] {
  const createdAt = new Date().toISOString();
  return [{
    allowed_permission_modes: ["deny", "once", "always"],
    created_at: createdAt,
    id: "feed-demo-permission",
    kind: "permissionRequest",
    source: "claude",
    status: "pending",
    tool_input: copy.demoPermissionBody,
    tool_name: copy.demoPermissionTitle,
    workstream_id: "feed-demo",
  }, {
    created_at: createdAt,
    id: "feed-demo-plan",
    kind: "exitPlan",
    plan: copy.demoPlanBody,
    source: "codex",
    status: "pending",
    title: copy.demoPlanTitle,
    workstream_id: "feed-demo",
  }, {
    created_at: createdAt,
    id: "feed-demo-question",
    kind: "question",
    question_prompt: copy.demoQuestionPrompt,
    questions: [{
      id: "verification",
      multi_select: false,
      options: [
        { id: "focused", label: copy.demoQuestionOptionFocused },
        { id: "full", label: copy.demoQuestionOptionFull },
      ],
      prompt: copy.demoQuestionPrompt,
    }],
    source: "gemini",
    status: "pending",
    title: copy.demoQuestionTitle,
    workstream_id: "feed-demo",
  }];
}

export function FeedApp() {
  const snapshot = useSyncExternalStore(
    feedSnapshotStore.subscribe,
    feedSnapshotStore.getSnapshot,
    feedSnapshotStore.getSnapshot,
  );
  const [filter, setFilter] = useState<Filter>("actionable");
  const [activityLimit, setActivityLimit] = useState(feedActivityPageSize);
  const [demoItems, setDemoItems] = useState<FeedItem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const keyboardCleanup = useRef<() => void>(() => {});
  const bindKeyboardRoot = useCallback((node: HTMLElement | null) => {
    keyboardCleanup.current();
    keyboardCleanup.current = () => {};
    if (!node) return;
    const onKeyDown = (event: KeyboardEvent) => handleFeedNavigation(event, node);
    node.addEventListener("keydown", onKeyDown);
    keyboardCleanup.current = () => node.removeEventListener("keydown", onKeyDown);
    if (!document.activeElement || document.activeElement === document.body) node.focus();
  }, []);

  if (!snapshot) return <main className="feed-shell feed-loading" aria-busy="true" />;
  const sourceItems = demoItems.length > 0 ? [...demoItems, ...snapshot.items] : snapshot.items;
  const items = filter === "actionable"
    ? sourceItems.filter((item) => item.status === "pending")
    : sourceItems;
  const visibleItems = filter === "activity" ? items.slice(0, activityLimit) : items;
  const hasBufferedActivity = filter === "activity" && visibleItems.length < items.length;
  const themeStyle = {
    "--feed-background": snapshot.theme.background,
    "--feed-foreground": snapshot.theme.foreground,
    colorScheme: snapshot.theme.isLight ? "light" : "dark",
  } as CSSProperties;

  const perform = async (method: string, params: Record<string, unknown>) => {
    setError(null);
    const itemId = typeof params.itemId === "string" ? params.itemId : "";
    if (itemId.startsWith("feed-demo-")) {
      setDemoItems((current) => current.map((item) => (
        item.id === itemId ? { ...item, status: "resolved" } : item
      )));
      return;
    }
    try {
      await callFeedNative(method, params);
    } catch {
      setError(snapshot.copy.requestFailed);
    }
  };

  return (
    <main
      className="feed-shell"
      style={themeStyle}
    >
      <div
        aria-label={snapshot.copy.feed}
        className="feed-keyboard-root"
        ref={bindKeyboardRoot}
        tabIndex={-1}
      >
      <header className="feed-header">
        <h1>{snapshot.copy.feed}</h1>
        <div className="feed-filter" onKeyDown={handleTabNavigation} role="tablist" tabIndex={-1}>
          <button
            aria-selected={filter === "actionable"}
            onClick={() => setFilter("actionable")}
            role="tab"
            tabIndex={filter === "actionable" ? 0 : -1}
          >
            {snapshot.copy.actionable}
          </button>
          <button
            aria-selected={filter === "activity"}
            onClick={() => setFilter("activity")}
            role="tab"
            tabIndex={filter === "activity" ? 0 : -1}
          >
            {snapshot.copy.activity}
          </button>
        </div>
      </header>
      {error && <div className="feed-error" role="alert">{error}</div>}
      <section className="feed-list">
        {visibleItems.length === 0 ? (
          <FeedEmptyState
            filter={filter}
            onLoadExamples={() => {
              setDemoItems(createDemoFeedItems(snapshot.copy));
              setFilter("actionable");
            }}
            snapshot={snapshot}
          />
        ) : visibleItems.map((item) => (
          <FeedCard
            key={item.id}
            item={item}
            copy={snapshot.copy}
            perform={perform}
            sourceIcon={snapshot.sourceIcons[item.source]}
            sourceLabel={snapshot.sourceLabels[item.source]}
          />
        ))}
        {(hasBufferedActivity || snapshot.hasMore) && (
          <button
            className="feed-load-more"
            disabled={!hasBufferedActivity && snapshot.isLoadingOlder}
            onClick={() => {
              if (hasBufferedActivity) {
                setActivityLimit((current) => current + feedActivityPageSize);
              } else {
                void perform("feed.loadOlder", {});
              }
            }}
          >
            {!hasBufferedActivity && snapshot.isLoadingOlder ? snapshot.copy.loadingOlder : snapshot.copy.loadOlder}
          </button>
        )}
      </section>
      </div>
    </main>
  );
}

function FeedEmptyState({ filter, onLoadExamples, snapshot }: {
  filter: Filter;
  onLoadExamples: () => void;
  snapshot: NonNullable<ReturnType<typeof feedSnapshotStore.getSnapshot>>;
}) {
  const title = filter === "actionable" ? snapshot.copy.emptyActionable : snapshot.copy.emptyActivity;
  const description = filter === "actionable"
    ? snapshot.copy.emptyActionableDescription
    : snapshot.copy.emptyActivityDescription;
  const statusLabel = (integration: FeedIntegration) => ({
    checking: snapshot.copy.integrationChecking,
    disabled: snapshot.copy.integrationDisabled,
    needsSetup: snapshot.copy.integrationNeedsSetup,
    ready: snapshot.copy.integrationReady,
  })[integration.status];
  return (
    <div className="feed-empty">
      <h2>{title}</h2>
      <p>{description}</p>
      <button className="feed-load-examples" onClick={onLoadExamples}>{snapshot.copy.loadExamples}</button>
      <section aria-labelledby="feed-integrations-title" className="feed-integrations">
        <h3 id="feed-integrations-title">{snapshot.copy.integrationsTitle}</h3>
        <div className="feed-integration-grid">
          {snapshot.integrations.map((integration) => (
            <div className="feed-integration" data-status={integration.status} key={integration.source}>
              <SourceIdentity
                icon={snapshot.sourceIcons[integration.source]}
                label={snapshot.sourceLabels[integration.source]}
                source={integration.source}
              />
              <span className="feed-integration-status">{statusLabel(integration)}</span>
            </div>
          ))}
        </div>
        <p className="feed-integration-hint">{snapshot.copy.integrationHint}</p>
      </section>
      <p className="feed-keyboard-help">{snapshot.copy.keyboardHelp}</p>
    </div>
  );
}

function FeedCard({ item, copy, perform, sourceIcon, sourceLabel }: {
  item: FeedItem;
  copy: NonNullable<ReturnType<typeof feedSnapshotStore.getSnapshot>>["copy"];
  perform: (method: string, params: Record<string, unknown>) => Promise<void>;
  sourceIcon?: string;
  sourceLabel?: string;
}) {
  const title = item.title || item.tool_name || item.kind.replaceAll("_", " ");
  return (
    <article className={`feed-card feed-card-${item.status}`} tabIndex={-1}>
      <div className="feed-card-heading">
        <div className="feed-card-title">
          <SourceIdentity icon={sourceIcon} label={sourceLabel} source={item.source} />
          <h2>{title}</h2>
        </div>
        <time>{new Date(item.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time>
      </div>
      {item.cwd && <div className="feed-cwd">{item.cwd}</div>}
      <FeedBody item={item} />
      {item.status === "pending" && (
        <FeedActions item={item} copy={copy} perform={perform} />
      )}
    </article>
  );
}

function SourceIdentity({ icon, label, source }: { icon?: string; label?: string; source: string }) {
  const displayLabel = label ?? source;
  const resolvedIcon = icon
    ? { presentation: "image" as const, url: icon }
    : feedSourceIcons[source];
  const style = resolvedIcon?.presentation === "mask"
    ? ({ "--feed-source-icon": `url(${JSON.stringify(resolvedIcon.url)})` } as CSSProperties)
    : undefined;
  return (
    <span className="feed-source" data-feed-source={source}>
      {resolvedIcon?.presentation === "image" ? (
        <img alt="" aria-hidden="true" className="feed-source-logo feed-source-logo-image" src={resolvedIcon.url} />
      ) : (
        <span
          className="feed-source-logo feed-source-logo-mask"
          data-fallback={resolvedIcon ? undefined : ""}
          style={style}
          aria-hidden="true"
        >
          {!resolvedIcon && displayLabel.slice(0, 1).toUpperCase()}
        </span>
      )}
      <span>{displayLabel}</span>
    </span>
  );
}

function FeedBody({ item }: { item: FeedItem }) {
  const text = item.plan || item.question_prompt || item.tool_input || item.tool_result || item.text;
  if (!text) return null;
  return <pre className="feed-body">{text}</pre>;
}

function FeedActions({ item, copy, perform }: {
  item: FeedItem;
  copy: NonNullable<ReturnType<typeof feedSnapshotStore.getSnapshot>>["copy"];
  perform: (method: string, params: Record<string, unknown>) => Promise<void>;
}) {
  if (item.kind === "permissionRequest") {
    const modes = new Set(item.allowed_permission_modes ?? ["deny"]);
    return <div className="feed-actions">
      {modes.has("deny") && <button className="danger" onClick={() => perform("feed.permission.reply", { itemId: item.id, mode: "deny" })}>{copy.deny}</button>}
      {modes.has("once") && <button onClick={() => perform("feed.permission.reply", { itemId: item.id, mode: "once" })}>{copy.allowOnce}</button>}
      {modes.has("always") && <button className="primary" onClick={() => perform("feed.permission.reply", { itemId: item.id, mode: "always" })}>{copy.allowAlways}</button>}
      {modes.has("all") && <button className="primary" onClick={() => perform("feed.permission.reply", { itemId: item.id, mode: "all" })}>{copy.allowAll}</button>}
      {modes.has("bypass") && <button className="danger" onClick={() => perform("feed.permission.reply", { itemId: item.id, mode: "bypass" })}>{copy.allowBypass}</button>}
    </div>;
  }
  if (item.kind === "exitPlan") {
    return <div className="feed-actions">
      <button onClick={() => perform("feed.exitPlan.reply", { itemId: item.id, mode: "manual" })}>{copy.planManual}</button>
      <button onClick={() => perform("feed.exitPlan.reply", { itemId: item.id, mode: "autoAccept" })}>{copy.planAuto}</button>
      <button className="primary" onClick={() => perform("feed.exitPlan.reply", { itemId: item.id, mode: "ultraplan" })}>{copy.planUltraplan}</button>
    </div>;
  }
  if (item.kind === "question") {
    return <QuestionActions item={item} questions={item.questions ?? []} copy={copy} perform={perform} />;
  }
  return null;
}

function QuestionActions({ item, questions, copy, perform }: {
  item: FeedItem;
  questions: FeedQuestion[];
  copy: NonNullable<ReturnType<typeof feedSnapshotStore.getSnapshot>>["copy"];
  perform: (method: string, params: Record<string, unknown>) => Promise<void>;
}) {
  const normalizedQuestions = questions.length > 0 ? questions : [{
    id: "question", multi_select: false, options: item.question_options ?? [], prompt: item.question_prompt ?? "",
  }];
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [freeText, setFreeText] = useState<Record<string, string>>({});
  const toggle = (question: FeedQuestion, id: string) => {
    setSelected((current) => {
      const values = current[question.id] ?? [];
      const next = question.multi_select
        ? (values.includes(id) ? values.filter((value) => value !== id) : [...values, id])
        : [id];
      return { ...current, [question.id]: next };
    });
  };
  const answers = normalizedQuestions.flatMap((question) => {
    const custom = freeText[question.id]?.trim();
    if (custom) return [custom];
    const values = selected[question.id] ?? [];
    const labels = question.options.filter((option) => values.includes(option.id)).map((option) => option.label);
    return labels.length > 0 ? [labels.join(", ")] : [];
  });
  return <div className="feed-question-actions">
    {normalizedQuestions.map((question) => <div className="feed-question" key={question.id}>
      {question.prompt && <div className="feed-question-prompt">{question.prompt}</div>}
      <div className="feed-options">
        {question.options.map((option) => (
          <button aria-pressed={(selected[question.id] ?? []).includes(option.id)} key={option.id} onClick={() => toggle(question, option.id)}>
            <strong>{option.label}</strong>
            {option.description && <span>{option.description}</span>}
          </button>
        ))}
      </div>
      <input
        aria-label={copy.questionPlaceholder}
        onChange={(event) => setFreeText((current) => ({ ...current, [question.id]: event.target.value }))}
        placeholder={copy.questionPlaceholder}
        value={freeText[question.id] ?? ""}
      />
    </div>)}
    <button className="primary" disabled={answers.length === 0} onClick={() => perform("feed.question.reply", { itemId: item.id, selections: answers })}>
      {copy.questionSubmit}
    </button>
  </div>;
}
