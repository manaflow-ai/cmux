// The composer's Run on N agents panel: the agents one prompt goes to, one row each (an agent, its
// model and its effort), 2 to 4 of them, and Run. It opens in a popover over the composer
// (Composer.tsx, ui/Popover: Escape and a press outside close it) from the + menu, the /run-on
// command or ⌘⇧Return, with Run focused so Return runs it. It starts with Claude Opus, Codex and Claude Sonnet when they are
// installed (runOnAgents.ts), and remembers nothing: each run picks again. A run that acpmux refuses
// keeps the panel and the prompt, and says why. Every row is the same height, so adding or removing
// an agent moves the rows under it by one row and nothing else.

import { useState, type Ref } from "react";
import { DialogButton } from "../../../ui/DialogButton";
import { Select, type SelectOption } from "../../../ui/Select";
import { useT } from "../i18n";
import type { PickerCatalog } from "../modelCatalogData";
import { SenderIcon } from "../subagents/SenderIcon";
import {
  MAX_RUNS,
  MIN_RUNS,
  defaultVariants,
  nextVariant,
  runHarnesses,
  variantEfforts,
  variantHarness,
  withModel,
  type RunVariant,
} from "./runOnAgents";
import "./runOnAgents.css";

export type RunOnAgentsPanelProps = {
  catalog: PickerCatalog | undefined;
  /// The prompt it runs: Run is off while it is empty.
  prompt: string;
  /// Starts the runs; a rejection keeps the panel open with its message.
  onRun(variants: RunVariant[]): Promise<unknown>;
  onClose(): void;
  /// The agents it opens with (the gallery's); else `defaultVariants`.
  initial?: RunVariant[];
  /// The Run button, which the popover focuses on open.
  runRef?: Ref<HTMLButtonElement>;
};

/// The value the selects use for "the harness's default".
const DEFAULT = "";

export function RunOnAgentsPanel({ catalog, prompt, onRun, onClose, initial, runRef }: RunOnAgentsPanelProps) {
  const t = useT();
  const [variants, setVariants] = useState<RunVariant[]>(() => initial ?? defaultVariants(catalog));
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string>();
  const harnesses = runHarnesses(catalog);
  const harnessOptions: SelectOption[] = harnesses.map((h) => ({ value: h.acpmuxHarness ?? h.id, label: h.name }));
  const canRun = !running && variants.length >= MIN_RUNS && Boolean(prompt.trim());
  const set = (index: number, next: RunVariant) =>
    setVariants((current) => current.map((v, i) => (i === index ? next : v)));
  const add = () => {
    const next = nextVariant(catalog, variants);
    if (next && variants.length < MAX_RUNS) setVariants([...variants, next]);
  };
  const run = () => {
    if (!canRun) return;
    setRunning(true);
    setError(undefined);
    onRun(variants).then(
      () => setRunning(false),
      (failure: unknown) => {
        setRunning(false);
        setError(failure instanceof Error ? failure.message : String(failure));
      },
    );
  };
  return (
    // Not a form: it sits inside the composer's own.
    <div className="acpmux-run-on">
      <header className="acpmux-run-on-head">
        <span className="acpmux-run-on-title">{t("runOn.title")}</span>
        <span className="acpmux-run-on-note" role={error ? "alert" : undefined}>
          {error ? t("runOn.failed", { error }) : !prompt.trim() ? t("runOn.emptyPrompt") : t("runOn.hint")}
        </span>
      </header>
      <ol className="acpmux-run-on-rows">
        {variants.map((variant, index) => {
          const harness = variantHarness(catalog, variant);
          const modelOptions: SelectOption[] = [
            { value: DEFAULT, label: t("runOn.defaultModel") },
            ...(harness?.models ?? [])
              .filter((m) => !m.unavailable)
              .map((m) => ({ value: m.id, label: m.shortName || m.name })),
          ];
          const efforts = variantEfforts(catalog, variant);
          const effortOptions: SelectOption[] = [
            { value: DEFAULT, label: t("runOn.defaultEffort") },
            ...efforts.map((e) => ({ value: e, label: e })),
          ];
          return (
            <li key={index} className="acpmux-run-on-row">
              <span className="acpmux-run-on-icon" aria-hidden>
                <SenderIcon harness={variant.harness} size={14} fallback="agent.chat" />
              </span>
              <Select
                className="acpmux-run-on-select"
                label={t("runOn.agent")}
                value={variant.harness}
                options={harnessOptions}
                closeOnPick
                onChange={(value) => set(index, { harness: value })}
              />
              <Select
                className="acpmux-run-on-select"
                label={t("runOn.model")}
                value={variant.model ?? DEFAULT}
                options={modelOptions}
                closeOnPick
                onChange={(value) => set(index, withModel(catalog, variant, value || undefined))}
              />
              <Select
                className="acpmux-run-on-select acpmux-run-on-effort"
                label={t("runOn.effort")}
                value={variant.effort ?? DEFAULT}
                options={effortOptions}
                disabled={!efforts.length}
                closeOnPick
                onChange={(value) => {
                  const { effort: _, ...rest } = variant;
                  set(index, value ? { ...rest, effort: value } : rest);
                }}
              />
              <button
                type="button"
                className="acpmux-run-on-remove"
                aria-label={t("runOn.remove")}
                title={t("runOn.remove")}
                disabled={variants.length <= MIN_RUNS || running}
                onClick={() => setVariants(variants.filter((_, i) => i !== index))}
              >
                ×
              </button>
            </li>
          );
        })}
      </ol>
      <footer className="acpmux-run-on-foot">
        <button
          type="button"
          className="acpmux-run-on-add"
          disabled={variants.length >= MAX_RUNS || running || !harnesses.length}
          onClick={add}
        >
          {t("runOn.add")}
        </button>
        <span className="acpmux-run-on-spacer" />
        <DialogButton dialogKey="escape" className="acpmux-run-on-cancel" onClick={onClose}>
          {t("runOn.cancel")}
        </DialogButton>
        <DialogButton
          ref={runRef}
          dialogKey="return"
          className="acpmux-run-on-run"
          onClick={run}
          disabled={!canRun}
          aria-busy={running || undefined}
        >
          {t("runOn.run", { n: variants.length })}
        </DialogButton>
      </footer>
    </div>
  );
}
