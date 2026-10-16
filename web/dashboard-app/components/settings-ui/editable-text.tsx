"use client";

import { useTranslations } from "next-intl";
import { useState } from "react";
import { InlineError } from "./feedback";
import { PencilIcon } from "./icons";
import { settingsButtonClass, settingsInputClass } from "./styles";
import { useAsyncAction } from "./use-async-action";

/**
 * Inline text with an edit button that swaps to an input plus Save and
 * Cancel. Values are trimmed; empty values are rejected unless
 * `allowEmpty` is set. A failed save keeps the editor open and shows the
 * error inline.
 */
export function EditableText({
  value,
  onSave,
  label,
  placeholder,
  emptyText,
  maxLength = 256,
  allowEmpty = false,
  disabled = false,
  describeError,
}: {
  readonly value: string;
  readonly onSave: (value: string) => Promise<void>;
  /** Accessible name of the input and the edit button. */
  readonly label: string;
  readonly placeholder?: string;
  /** Shown instead of the value when it is empty. */
  readonly emptyText?: string;
  readonly maxLength?: number;
  readonly allowEmpty?: boolean;
  readonly disabled?: boolean;
  /** Maps a failed save to display text; unknown failures show a generic error. */
  readonly describeError?: (error: unknown) => string | null;
}) {
  const t = useTranslations("dashboard.settings.ui");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value);
  const [run, state] = useAsyncAction(t("saveError"), describeError);

  const startEditing = () => {
    setDraft(value);
    state.clearError();
    setEditing(true);
  };

  const cancel = () => {
    setDraft(value);
    state.clearError();
    setEditing(false);
  };

  const save = async () => {
    const next = draft.trim();
    if (!allowEmpty && next.length === 0) {
      state.setError(t("required"));
      return;
    }
    if (next === value) {
      setEditing(false);
      return;
    }
    if (await run(() => onSave(next))) setEditing(false);
  };

  if (!editing) {
    return (
      <div className="flex min-w-0 items-center gap-2">
        <span className={`min-w-0 truncate ${value ? "" : "text-muted"}`}>
          {value || emptyText || "—"}
        </span>
        <button
          type="button"
          aria-label={t("editLabel", { label })}
          disabled={disabled}
          onClick={startEditing}
          className={settingsButtonClass("ghost", "sm")}
        >
          <PencilIcon />
        </button>
      </div>
    );
  }

  return (
    <form
      className="flex w-full flex-col gap-1 sm:max-w-sm"
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <div className="flex gap-2">
        <input
          aria-label={label}
          value={draft}
          maxLength={maxLength}
          placeholder={placeholder}
          autoFocus
          disabled={state.pending}
          onChange={(event) => {
            setDraft(event.target.value);
            state.clearError();
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape") cancel();
          }}
          className={settingsInputClass}
        />
        <button type="submit" disabled={state.pending} className={settingsButtonClass("primary", "sm")}>
          {state.pending ? t("saving") : t("save")}
        </button>
        <button type="button" disabled={state.pending} onClick={cancel} className={settingsButtonClass("secondary", "sm")}>
          {t("cancel")}
        </button>
      </div>
      <InlineError message={state.error} />
    </form>
  );
}
