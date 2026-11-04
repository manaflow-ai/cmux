import { useMemo, useState } from "react";
import "./contextViewer.css";

/** A single component of the effective harness context.
 *
 * `text` is the exact text sent to the harness. The viewer deliberately receives
 * structured parts from acpmux instead of reconstructing the prompt in the web
 * view, so source labels and token counts cannot drift from what was sent.
 */
export type ContextPart = {
  id: string;
  label: string;
  source: string;
  text: string;
  tokenCount: number;
  editable?: boolean;
  scope?: "builtin" | "user" | "project" | "session";
  applied?: boolean;
};

export type ContextOverrideScope = "user" | "project";

export type ContextViewerProps = {
  parts: readonly ContextPart[];
  /** Optional context metadata shown beside the total. */
  harness?: string;
  sessionId?: string;
  loading?: boolean;
  error?: string;
  onSaveOverride?: (part: ContextPart, text: string, scope: ContextOverrideScope) => void | Promise<void>;
  onResetOverride?: (part: ContextPart, scope: ContextOverrideScope) => void | Promise<void>;
  onClose?: () => void;
};

function tokenLabel(count: number): string {
  return `${count.toLocaleString()} token${count === 1 ? "" : "s"}`;
}

function sourceLabel(part: ContextPart): string {
  const scope = part.scope && part.scope !== "builtin" ? ` · ${part.scope}` : "";
  return `${part.source}${scope}`;
}

function PartRow({ part, onSaveOverride, onResetOverride }: Pick<ContextViewerProps, "onSaveOverride" | "onResetOverride"> & { part: ContextPart }) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(part.text);
  const [scope, setScope] = useState<ContextOverrideScope>(part.scope === "project" ? "project" : "user");
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState<string>();
  const dirty = draft !== part.text;
  const detailsId = `context-part-${part.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;

  const save = async () => {
    if (!onSaveOverride || !dirty || saving) return;
    setSaving(true);
    setNotice(undefined);
    try {
      await onSaveOverride(part, draft, scope);
      setNotice("Saved for the next session");
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Could not save override");
    } finally {
      setSaving(false);
    }
  };

  const reset = async () => {
    if (!onResetOverride || saving) return;
    setSaving(true);
    setNotice(undefined);
    try {
      await onResetOverride(part, scope);
      setDraft(part.text);
      setNotice("Override reset");
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Could not reset override");
    } finally {
      setSaving(false);
    }
  };

  return (
    <article className="acpmux-context-part" data-part-id={part.id} data-applied={part.applied !== false}>
      <button
        type="button"
        className="acpmux-context-part__head"
        aria-expanded={open}
        aria-controls={detailsId}
        onClick={() => setOpen((value) => !value)}
      >
        <span className={`acpmux-context-part__chevron${open ? " is-open" : ""}`} aria-hidden="true">›</span>
        <span className="acpmux-context-part__name">{part.label}</span>
        <span className="acpmux-context-part__source">{sourceLabel(part)}</span>
        <span className="acpmux-context-part__tokens">{tokenLabel(part.tokenCount)}</span>
      </button>
      {open && (
        <div id={detailsId} className="acpmux-context-part__body">
          {part.editable ? (
            <>
              <textarea
                className="acpmux-context-part__editor"
                aria-label={`${part.label} prompt`}
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                spellCheck={false}
                rows={Math.min(16, Math.max(4, draft.split("\n").length + 1))}
              />
              <div className="acpmux-context-part__actions">
                <label className="acpmux-context-part__scope">
                  <span>Save override</span>
                  <select value={scope} onChange={(event) => setScope(event.target.value as ContextOverrideScope)} disabled={saving}>
                    <option value="user">For me</option>
                    <option value="project">For this project</option>
                  </select>
                </label>
                <button type="button" className="acpmux-context-part__save" disabled={!dirty || saving || !onSaveOverride} onClick={save}>
                  {saving ? "Saving…" : "Save"}
                </button>
                {onResetOverride && (
                  <button type="button" className="acpmux-context-part__reset" disabled={saving} onClick={reset}>
                    Reset
                  </button>
                )}
              </div>
              {notice && <p className="acpmux-context-part__notice" role="status">{notice}</p>}
            </>
          ) : (
            <pre className="acpmux-context-part__text">{part.text}</pre>
          )}
        </div>
      )}
    </article>
  );
}

/** The session-scoped Context tab. It is intentionally transport-agnostic: the
 * native page provider owns fetching and persistence, while this component only
 * renders exact parts and emits override edits. */
export function ContextViewer({
  parts,
  harness,
  sessionId,
  loading = false,
  error,
  onSaveOverride,
  onResetOverride,
  onClose,
}: ContextViewerProps) {
  const totalTokens = useMemo(() => parts.reduce((sum, part) => sum + Math.max(0, part.tokenCount), 0), [parts]);
  return (
    <section className="acpmux-context-viewer" aria-label="Context" data-harness={harness} data-session-id={sessionId}>
      <header className="acpmux-context-viewer__header">
        {onClose && <button type="button" className="acpmux-context-viewer__back" aria-label="Close Context" onClick={onClose}>‹</button>}
        <div className="acpmux-context-viewer__heading">
          <h1>Context</h1>
          <p>{harness ? `${harness} · ` : ""}{tokenLabel(totalTokens)}</p>
        </div>
        <span className="acpmux-context-viewer__count">{parts.length} {parts.length === 1 ? "part" : "parts"}</span>
      </header>
      {loading && <p className="acpmux-context-viewer__state" role="status">Loading context…</p>}
      {error && <p className="acpmux-context-viewer__state is-error" role="alert">{error}</p>}
      {!loading && !error && parts.length === 0 && <p className="acpmux-context-viewer__state">No context was sent.</p>}
      {!loading && !error && parts.length > 0 && (
        <div className="acpmux-context-viewer__parts">
          {parts.map((part) => <PartRow key={part.id} part={part} onSaveOverride={onSaveOverride} onResetOverride={onResetOverride} />)}
        </div>
      )}
    </section>
  );
}

