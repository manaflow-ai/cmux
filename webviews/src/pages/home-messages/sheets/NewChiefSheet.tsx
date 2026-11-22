// New Chief: a name for another Chief and the engine it runs on (Claude, Codex, Muse Code or
// UniiChat); the Chief gets its own conversation. The host makes it where the engine needs it
// (a Claude Chief is the account's cloud Chief, the others are this Mac's). The chosen engine's
// one-line note shows under the picker. Create (↩) waits for a name of at most 100 characters.
// While the host works the status line says so, and says it is slow when it is: a Create button that
// only greys out reads as a dialog that does not work.
import { useEffect, useId, useState } from "react";
import type { Strings } from "../../shared/i18n";
import { Select } from "../../../ui/Select";
import type { ComposeActions } from "./actions";
import { CHIEF_BACKEND_CHOICES, CHIEF_NAME_MAX } from "./model";
import { SheetFrame, useSheetRun } from "./SheetFrame";

/** How long Create runs before the status line says it is taking a while. */
const CHIEF_CREATE_SLOW_MS = 8000;

export interface NewChiefSheetProps {
  strings: Strings;
  actions: Pick<ComposeActions, "createChief">;
  onFinish(conversation: string | null): void;
  /** The name to start with (the gallery). */
  initialName?: string;
  initialBackend?: string;
  /** How long Create runs before it says it is slow (tests). */
  slowAfterMs?: number;
}

export function NewChiefSheet({
  strings,
  actions,
  onFinish,
  initialName = "",
  initialBackend,
  slowAfterMs = CHIEF_CREATE_SLOW_MS,
}: NewChiefSheetProps) {
  const { t } = strings;
  const sheet = useSheetRun(strings, onFinish);
  const [name, setName] = useState(initialName);
  const [backend, setBackend] = useState(initialBackend ?? CHIEF_BACKEND_CHOICES[0]!.id);
  const label = useId();
  const { running, setStatus } = sheet;
  useEffect(() => {
    if (!running) return;
    setStatus(t("home.chief.new.creating"));
    const slow = setTimeout(() => setStatus(t("home.chief.new.slow")), slowAfterMs);
    return () => clearTimeout(slow);
  }, [running, setStatus, slowAfterMs, t]);
  const trimmed = name.trim();
  const canSubmit = trimmed !== "" && Array.from(trimmed).length <= CHIEF_NAME_MAX;
  const chosen = CHIEF_BACKEND_CHOICES.find((choice) => choice.id === backend) ?? CHIEF_BACKEND_CHOICES[0]!;
  return (
    <SheetFrame
      strings={strings}
      id="cmux.home.chief"
      title={t("home.chief.new.title")}
      primary={t("home.chief.new.create")}
      canSubmit={canSubmit}
      running={sheet.running}
      status={sheet.status}
      onSubmit={() => sheet.run(() => actions.createChief(trimmed, chosen.id))}
      onCancel={() => sheet.finish(null)}
    >
      <p className="hm-sheet-body">{t("home.chief.new.body")}</p>
      <input
        className="hc-link-field"
        value={name}
        placeholder={t("home.chief.new.name")}
        aria-label={t("home.chief.new.name")}
        data-testid="cmux.home.chief.name"
        onChange={(event) => setName(event.target.value)}
      />
      <span id={label} className="hm-sheet-caption">
        {t("home.chief.new.backend")}
      </span>
      <Select
        value={chosen.id}
        label={t("home.chief.new.backend")}
        labelledBy={label}
        closeOnPick
        options={CHIEF_BACKEND_CHOICES.map((choice) => ({ value: choice.id, label: t(choice.title) }))}
        onChange={setBackend}
      />
      {chosen.hint && (
        <p className="hm-sheet-caption" data-testid="cmux.home.chief.backendHint">
          {t(chosen.hint)}
        </p>
      )}
    </SheetFrame>
  );
}
