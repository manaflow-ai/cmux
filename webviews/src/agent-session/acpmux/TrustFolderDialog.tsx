import React, { useLayoutEffect, useRef, useState } from "react";

/// Dialog copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const TRUST_LABELS = {
  title: "Trust this folder?",
  body: "{agent} can read, edit, and execute files here. Folder settings can also run code automatically, even without a model request. Continue only if you trust these files.",
  trust: "Trust folder",
  cancel: "Cancel",
  close: "Close",
  failed: "Couldn't save that. Try again.",
  /// The agent's name when the session doesn't say which agent it runs.
  agent: "The agent",
};

/// Codex's "Trust this folder?" (codex-atlas-clone reference fixture-trust-dialog), asked
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
        <button type="button" className="acpmux-trust-close" aria-label={TRUST_LABELS.close} onClick={onCancel}>
          <svg width={14} height={14} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
            <path d="m4 4 8 8M12 4l-8 8" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" />
          </svg>
        </button>
        <h2 id={titleId} className="acpmux-trust-title">
          {TRUST_LABELS.title}
        </h2>
        <div className="acpmux-trust-path">{cwd}</div>
        <p id={bodyId} className="acpmux-trust-body">
          {TRUST_LABELS.body.replace("{agent}", agent)}
        </p>
        {failed && (
          <p className="acpmux-trust-error" role="alert">
            {TRUST_LABELS.failed}
          </p>
        )}
        <button ref={trustButton} type="button" className="acpmux-trust-primary" aria-busy={saving} onClick={trust}>
          {TRUST_LABELS.trust}
        </button>
        <button type="button" className="acpmux-trust-secondary" onClick={onCancel}>
          {TRUST_LABELS.cancel}
        </button>
      </dialog>
    </div>
  );
}
