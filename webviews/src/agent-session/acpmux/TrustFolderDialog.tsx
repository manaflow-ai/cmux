import React, { useLayoutEffect, useRef, useState } from "react";
import { t } from "./i18n";

/// "Trust this folder?", asked
/// before the first prompt in a folder the user hasn't decided on. Trust folder records the
/// decision and lets the prompt go; Cancel, the close button and Escape keep the prompt unsent.
export function TrustFolderDialog({
  cwd,
  agent,
  onTrust,
  onCancel,
}: {
  cwd: string;
  agent: string;
  /// Records the decision; a rejection keeps the dialog up with an error.
  onTrust(): Promise<unknown>;
  onCancel(): void;
}) {
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const trustButton = useRef<HTMLButtonElement>(null);
  const scrim = useRef<HTMLDivElement>(null);
  const titleId = React.useId();
  const bodyId = React.useId();

  // A layout effect: the pane is inert before the first paint, and stops being inert in the same
  // commit that removes the dialog, so whatever the answer refocuses can take focus.
  useLayoutEffect(() => {
    // Focus goes back where it was (the prompt, or Send) once the dialog is gone.
    const before = document.activeElement as HTMLElement | null;
    // Modal: the rest of the pane takes no focus, clicks or typing until the user answers.
    const others = [...(scrim.current?.parentElement?.children ?? [])].filter(
      (node): node is HTMLElement =>
        node !== scrim.current && node instanceof HTMLElement && !node.hasAttribute("inert"),
    );
    for (const node of others) node.setAttribute("inert", "");
    trustButton.current?.focus();
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      cancelRef.current();
    };
    document.addEventListener("keydown", escape, true);
    return () => {
      document.removeEventListener("keydown", escape, true);
      for (const node of others) node.removeAttribute("inert");
      // A refocus that ran while the pane was still inert did nothing; the dialog's own goes now.
      const lost = !document.activeElement || document.activeElement === document.body;
      if (lost && before?.isConnected) before.focus();
    };
  }, []);
  const cancelRef = useRef(onCancel);
  cancelRef.current = onCancel;

  const trust = () => {
    if (saving) return;
    setSaving(true);
    setFailed(false);
    onTrust().then(
      () => setSaving(false),
      () => {
        setSaving(false);
        setFailed(true);
      },
    );
  };

  return (
    <div ref={scrim} className="acpmux-trust-scrim">
      <dialog open className="acpmux-trust" aria-modal="true" aria-labelledby={titleId} aria-describedby={bodyId}>
        <button type="button" className="acpmux-trust-close" aria-label={t("trust.close")} onClick={onCancel}>
          <svg width={14} height={14} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
            <path d="m4 4 8 8M12 4l-8 8" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" />
          </svg>
        </button>
        <h2 id={titleId} className="acpmux-trust-title">
          {t("trust.title")}
        </h2>
        <div className="acpmux-trust-path">{cwd}</div>
        <p id={bodyId} className="acpmux-trust-body">
          {t("trust.body", { agent })}
        </p>
        {failed && (
          <p className="acpmux-trust-error" role="alert">
            {t("trust.failed")}
          </p>
        )}
        <button ref={trustButton} type="button" className="acpmux-trust-primary" aria-busy={saving} onClick={trust}>
          {t("trust.trust")}
        </button>
        <button type="button" className="acpmux-trust-secondary" onClick={onCancel}>
          {t("trust.cancel")}
        </button>
      </dialog>
    </div>
  );
}
