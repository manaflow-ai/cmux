import { useState, useSyncExternalStore } from "react";
import { callFeedNative, feedSnapshotStore } from "./bridge";
import type { FeedItem, FeedQuestion } from "./types";
import "./styles.css";

type Filter = "actionable" | "activity";

export function FeedApp() {
  const snapshot = useSyncExternalStore(
    feedSnapshotStore.subscribe,
    feedSnapshotStore.getSnapshot,
    feedSnapshotStore.getSnapshot,
  );
  const [filter, setFilter] = useState<Filter>("actionable");
  const [error, setError] = useState<string | null>(null);

  if (!snapshot) return <main className="feed-shell feed-loading" aria-busy="true" />;
  const items = filter === "actionable"
    ? snapshot.items.filter((item) => item.status === "pending")
    : snapshot.items;

  const perform = async (method: string, params: Record<string, unknown>) => {
    setError(null);
    try {
      await callFeedNative(method, params);
    } catch {
      setError(snapshot.copy.requestFailed);
    }
  };

  return (
    <main className="feed-shell">
      <header className="feed-header">
        <h1>{snapshot.copy.feed}</h1>
        <div className="feed-filter" role="tablist">
          <button aria-selected={filter === "actionable"} onClick={() => setFilter("actionable")} role="tab">
            {snapshot.copy.actionable}
          </button>
          <button aria-selected={filter === "activity"} onClick={() => setFilter("activity")} role="tab">
            {snapshot.copy.activity}
          </button>
        </div>
      </header>
      {error && <div className="feed-error" role="alert">{error}</div>}
      <section className="feed-list">
        {items.length === 0 ? (
          <div className="feed-empty">
            {filter === "actionable" ? snapshot.copy.emptyActionable : snapshot.copy.emptyActivity}
          </div>
        ) : items.map((item) => (
          <FeedCard key={item.id} item={item} copy={snapshot.copy} perform={perform} />
        ))}
        {snapshot.hasMore && (
          <button
            className="feed-load-more"
            disabled={snapshot.isLoadingOlder}
            onClick={() => perform("feed.loadOlder", {})}
          >
            {snapshot.isLoadingOlder ? snapshot.copy.loadingOlder : snapshot.copy.loadOlder}
          </button>
        )}
      </section>
    </main>
  );
}

function FeedCard({ item, copy, perform }: {
  item: FeedItem;
  copy: NonNullable<ReturnType<typeof feedSnapshotStore.getSnapshot>>["copy"];
  perform: (method: string, params: Record<string, unknown>) => Promise<void>;
}) {
  const title = item.title || item.tool_name || item.kind.replaceAll("_", " ");
  return (
    <article className={`feed-card feed-card-${item.status}`}>
      <div className="feed-card-heading">
        <div>
          <span className="feed-source">{item.source}</span>
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
