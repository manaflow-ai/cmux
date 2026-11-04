import { useEffect, useId, useMemo, useState } from "react";
import { useT, type Translate } from "./i18n";
import "./contextViewer.css";

/** One labelled component of the context snapshot acpmux sent to a harness. */
export type ContextPart = {
  id: string;
  label: string;
  source: string;
  /** Exact provider text, when the provider exposes it. */
  text: string;
  /** Undefined or `measurement: unavailable` means the count is unknown. */
  tokenCount?: number;
  measurement?: "measured" | "estimated" | "unavailable";
  /** Provider-owned text may be withheld even when its token count is measured. */
  textAvailable?: boolean;
  /** Kept for inventory compatibility; effective session parts are never edited here. */
  editable?: boolean;
  scope?: "builtin" | "user" | "project" | "session";
  applied?: boolean;
  channel?: string;
};

export type ContextOverrideScope = "user" | "project";

export type ContextSettings = {
  user: string | null;
  project: string | null;
  defaultText?: string;
  cwd?: string;
};

export type ContextViewerProps = {
  parts: readonly ContextPart[];
  /** Provider-reported total. Detail rows are not summed because nested provider rows overlap. */
  totalTokens?: number;
  /** Approximate budget, when the provider reports one. */
  maxTokens?: number;
  /** cmux-owned estimate, shown separately from provider totals. */
  cmuxTokens?: number;
  settings?: ContextSettings;
  harness?: string;
  sessionId?: string;
  loading?: boolean;
  error?: string;
  onSaveOverride?: (scope: ContextOverrideScope, text: string) => void | Promise<void>;
  onResetOverride?: (scope: ContextOverrideScope) => void | Promise<void>;
  onRefresh?: () => void | Promise<void>;
  onClose?: () => void;
};

function tokenLabel(count: number | undefined, t: Translate): string {
  if (count === undefined || !Number.isFinite(count)) return t("context.tokenCountUnavailable");
  return t(count === 1 ? "context.tokens.one" : "context.tokens.other", { n: count.toLocaleString() });
}

function measurementLabel(part: ContextPart, t: Translate): string {
  if (part.tokenCount === undefined || part.measurement === "unavailable") return t("context.unavailable");
  return part.measurement === "estimated" ? t("context.estimated") : t("context.measured");
}

function sourceLabel(part: ContextPart, t: Translate): string {
  const scope = part.scope && part.scope !== "builtin" ? ` · ${part.scope}` : "";
  return `${part.source}${scope}${part.channel ? ` · ${part.channel}` : ""}${part.applied === false ? ` · ${t("context.notIncluded")}` : ""}`;
}

function PartRow({
  part,
  t,
  open,
  onToggle,
}: {
  part: ContextPart;
  t: Translate;
  open: boolean;
  onToggle: () => void;
}) {
  const detailsId = useId();
  const unavailable = part.textAvailable === false;
  return (
    <article className="acpmux-context-part" data-part-id={part.id} data-applied={part.applied !== false}>
      <button
        type="button"
        className="acpmux-context-part__head"
        aria-expanded={open}
        aria-controls={detailsId}
        onClick={onToggle}
      >
        <span className={`acpmux-context-part__chevron${open ? " is-open" : ""}`} aria-hidden="true">
          ›
        </span>
        <span className="acpmux-context-part__name">{part.label}</span>
        <span className="acpmux-context-part__source">{sourceLabel(part, t)}</span>
        <span className="acpmux-context-part__tokens">
          {tokenLabel(part.measurement === "unavailable" ? undefined : part.tokenCount, t)} ·{" "}
          {measurementLabel(part, t)}
        </span>
      </button>
      {open && (
        <div id={detailsId} className="acpmux-context-part__body">
          {unavailable ? (
            <p className="acpmux-context-part__text is-unavailable">{t("context.notExposed")}</p>
          ) : (
            <pre className="acpmux-context-part__text">{part.text}</pre>
          )}
        </div>
      )}
    </article>
  );
}

function NextSessionEditor({
  settings,
  fallbackText,
  onSaveOverride,
  onResetOverride,
}: Pick<ContextViewerProps, "settings" | "onSaveOverride" | "onResetOverride"> & {
  fallbackText?: string;
}) {
  const t = useT();
  const currentSettings = settings ?? { user: null, project: null, defaultText: fallbackText };
  const initialScope: ContextOverrideScope = currentSettings.project !== null ? "project" : "user";
  const [scope, setScope] = useState<ContextOverrideScope>(initialScope);
  const persisted = currentSettings[scope];
  const inherited =
    scope === "project"
      ? (currentSettings.user ?? currentSettings.defaultText ?? fallbackText ?? "")
      : (currentSettings.defaultText ?? fallbackText ?? "");
  const [draft, setDraft] = useState(persisted ?? inherited);
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<string>();

  useEffect(() => {
    setDraft(persisted ?? inherited);
  }, [persisted, inherited, scope]);
  const dirty = draft !== (persisted ?? inherited);
  const hasOverride = persisted !== null;
  const save = async () => {
    if (!onSaveOverride || !dirty || saving) return;
    setSaving(true);
    setNotice(undefined);
    try {
      // An empty value is intentional: it disables this cmux addition for the next session.
      await onSaveOverride(scope, draft);
      setNotice(t("context.saved"));
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t("context.saveFailed"));
    } finally {
      setSaving(false);
    }
  };
  const reset = async () => {
    if (!onResetOverride || !hasOverride || saving) return;
    setSaving(true);
    setNotice(undefined);
    try {
      await onResetOverride(scope);
      setNotice(t("context.resetDone"));
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t("context.resetFailed"));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="acpmux-context-editor" aria-label={t("context.nextSessionOverride")} data-context-editor>
      <div className="acpmux-context-editor__heading">
        <div>
          <h2>{t("context.nextSession")}</h2>
          <p>{t("context.nextSessionDescription")}</p>
        </div>
        <label className="acpmux-context-part__scope">
          <span>{t("context.scope")}</span>
          <select
            value={scope}
            onChange={(event) => setScope(event.target.value as ContextOverrideScope)}
            disabled={saving}
          >
            <option value="user">{t("context.scope.user")}</option>
            <option value="project">{t("context.scope.project")}</option>
          </select>
        </label>
      </div>
      {currentSettings.project !== null && (
        <p className="acpmux-context-editor__note">{t("context.projectReplacesUser")}</p>
      )}
      <textarea
        className="acpmux-context-editor__textarea"
        aria-label={t("context.nextSessionGuidance")}
        placeholder={inherited ? undefined : t("context.noOverride")}
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        spellCheck={false}
        rows={Math.min(12, Math.max(4, draft.split("\n").length + 1))}
        disabled={saving}
      />
      <div className="acpmux-context-editor__actions">
        <button
          type="button"
          className="acpmux-context-part__save"
          disabled={!dirty || saving || !onSaveOverride}
          onClick={save}
        >
          {saving ? t("context.saving") : t("context.save")}
        </button>
        <button
          type="button"
          className="acpmux-context-part__reset"
          disabled={!hasOverride || saving || !onResetOverride}
          onClick={reset}
        >
          {t("context.reset")}
        </button>
        <span className="acpmux-context-editor__hint">{t("context.emptyDisables")}</span>
      </div>
      {notice && (
        <p className="acpmux-context-part__notice" role="status">
          {notice}
        </p>
      )}
    </section>
  );
}

/** Session evidence is read-only; the separate editor applies only to the next session. */
export function ContextViewer({
  parts,
  totalTokens,
  maxTokens,
  cmuxTokens,
  settings,
  harness,
  sessionId,
  loading = false,
  error,
  onSaveOverride,
  onResetOverride,
  onRefresh,
  onClose,
}: ContextViewerProps) {
  const t = useT();
  const [expanded, setExpanded] = useState<{ sessionId?: string; partId: string }>();
  const fallbackText = useMemo(
    () => settings?.defaultText ?? parts.find((part) => part.editable && part.textAvailable !== false)?.text,
    [parts, settings?.defaultText],
  );
  return (
    <section
      className="acpmux-context-viewer"
      aria-label={t("context.viewer.title")}
      data-harness={harness}
      data-session-id={sessionId}
    >
      <header className="acpmux-context-viewer__header">
        {onClose && (
          <button
            type="button"
            className="acpmux-context-viewer__back"
            aria-label={t("context.close")}
            onClick={onClose}
          >
            ‹
          </button>
        )}
        <div className="acpmux-context-viewer__heading">
          <h1>{t("context.viewer.title")}</h1>
          <p>
            {harness ? `${harness} · ` : ""}
            {tokenLabel(totalTokens, t)}
            {maxTokens !== undefined ? ` · ${t("context.tokenBudget", { count: tokenLabel(maxTokens, t) })}` : ""}
          </p>
          {cmuxTokens !== undefined && <small>{t("context.cmuxEstimate", { count: tokenLabel(cmuxTokens, t) })}</small>}
        </div>
        <span className="acpmux-context-viewer__count">
          {t(parts.length === 1 ? "context.parts.one" : "context.parts.other", { n: parts.length.toLocaleString() })}
        </span>
        {onRefresh && (
          <button type="button" className="acpmux-context-viewer__refresh" onClick={onRefresh} disabled={loading}>
            {error ? t("context.retry") : t("context.refresh")}
          </button>
        )}
      </header>
      {loading && (
        <p className="acpmux-context-viewer__state" role="status">
          {t("context.loading")}
        </p>
      )}
      {error && (
        <p className="acpmux-context-viewer__state is-error" role="alert">
          {error}
        </p>
      )}
      {!loading && !error && parts.length === 0 && <p className="acpmux-context-viewer__state">{t("context.empty")}</p>}
      {!loading && !error && parts.length > 0 && (
        <div className="acpmux-context-viewer__parts">
          {parts.map((part) => (
            <PartRow
              key={`${sessionId ?? "context"}:${part.id}`}
              part={part}
              t={t}
              open={expanded?.sessionId === sessionId && expanded?.partId === part.id}
              onToggle={() =>
                setExpanded((current) =>
                  current?.sessionId === sessionId && current?.partId === part.id
                    ? undefined
                    : { sessionId, partId: part.id },
                )
              }
            />
          ))}
          {settings && (
            <NextSessionEditor
              key={sessionId}
              settings={settings}
              fallbackText={fallbackText}
              onSaveOverride={onSaveOverride}
              onResetOverride={onResetOverride}
            />
          )}
        </div>
      )}
      {!loading && !error && parts.length === 0 && settings && (
        <NextSessionEditor
          key={sessionId}
          settings={settings}
          fallbackText={fallbackText}
          onSaveOverride={onSaveOverride}
          onResetOverride={onResetOverride}
        />
      )}
    </section>
  );
}
