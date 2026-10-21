import React, { useCallback, useEffect, useId, useRef, useState } from "react";
import type { SignIn } from "./signIn";
import { useChatAccounts } from "./chatAccounts";
import type { QuickMenuExtras } from "./QuickModelMenu";
import { sessionModels } from "./modelCatalog";
import {
  isDefaultChoice,
  loadResolvedDefaults,
  modelIdName,
  rememberResolvedDefault,
  resolvedModel,
} from "./defaultChoice";
import { loadLastChips, rememberLastChips } from "./chipMemory";
import type { AcpmuxSnapshot } from "./model";
import { EffortLabel, EffortPicker, type SpeedSection } from "./EffortPicker";
import { type SpeedTiers, useSpeedToggle } from "./FastToggle";
import { type StringKey, useT } from "./i18n";
import { ModelPicker } from "./ModelPicker";
import type { CatalogRefreshState, ModelCombo, ModelPickerProps } from "./modelPickerLayout";
import { topModelsFor } from "./topModels";
import { rememberPick } from "./lastPick";
import { defaultModel } from "./harnessSwitch";
import { catalogRow } from "./catalogRow";
import { harnessProfiles } from "./harnessProfiles";
import { useStartMode } from "./startMode";
import type { PickerCatalog } from "./modelCatalogData";
import { focusWithRing } from "../../ui/focusWithRing";
import { Popover } from "../../ui/Popover";
import { ContextMenu } from "../../ui/ContextMenu";
import { useComposerSettings } from "./composerSettings";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { registerPicker } from "./pickerOpeners";
import { UI_ANCHOR_GAP, useUiAnchor } from "../../ui/anchor";
import { useEscapingPopup } from "../../ui/popupHost";
import { usePopupHost } from "../../ui/UiProvider";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { isMousePress } from "../../ui/pressRelease";
import { focusAfterEscape } from "../../ui/escapeFocus";

/// Picker copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const PICKER_LABELS = {
  model: "picker.model",
  mode: "picker.mode",
  /// The access chip's tooltip: what the control is (a tester asked what the shield chip does).
  modeHelp: "picker.modeHelp",
  /// A mode the agent or the organization's managed settings refused.
  modeRefused: "picker.modeRefused",
  effort: "picker.effort",
  plan: "picker.plan",
  build: "picker.build",
  fullAccessWarning: "picker.fullAccessWarning",
  /// `{percent}` is the share of the context window used.
  context: "picker.context",
} as const satisfies Record<string, StringKey>;

/// A model and effort the viewer used, kept per viewer so the menu can offer it as one click.
export type Combo = { harness: string; model: string; effort?: string; effortName?: string };
/// A combo counts as used once it has held this long: model and effort land in separate updates.
export const RECENT_SETTLE_MS = 1500;
const RECENTS_KEY = "cmux.acpmux.recentModels";

/// The viewer's recent combos, newest first. Storage can be missing or blocked; then there are none.
export function loadRecents(): Combo[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(RECENTS_KEY) ?? "[]");
    return Array.isArray(value)
      ? value.filter(
          (combo): combo is Combo =>
            typeof combo?.harness === "string" &&
            typeof combo.model === "string" &&
            (combo.effort === undefined || typeof combo.effort === "string") &&
            (combo.effortName === undefined || typeof combo.effortName === "string"),
        )
      : [];
  } catch {
    return [];
  }
}

/// Puts `combo` first, once, and keeps the list short. Saving is best effort.
/// It builds on what is stored now, so another pane's newer combos aren't written over.
export function rememberCombo(recents: Combo[], combo: Combo): Combo[] {
  const key = (other: Combo) => `${other.harness}\u0000${other.model}\u0000${other.effort ?? ""}`;
  const same = (other: Combo) => key(other) === key(combo);
  const known = new Set<string>();
  const merged = [...loadRecents(), ...recents].filter((other) => !known.has(key(other)) && known.add(key(other)));
  if (merged[0] && same(merged[0])) return merged;
  const next = [combo, ...merged.filter((other) => !same(other))].slice(0, 12);
  try {
    localStorage.setItem(RECENTS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the list for this page only.
  }
  return next;
}

export type Choice = {
  id: string;
  name: string;
  description?: string;
  icon?: React.ReactNode;
  hint?: string;
  /// The level the model recommends (its catalog default): the effort slider marks it.
  recommended?: boolean;
};

/// Runs `run` after `ms` unless the returned cancel runs first.
export type SettleTimer = (run: () => void, ms: number) => () => void;

const browserSettleTimer: SettleTimer = (run, ms) => {
  const timer = setTimeout(run, ms);
  return () => clearTimeout(timer);
};

type Props = {
  snapshot: AcpmuxSnapshot;
  /** Granted folder trust and chat-wide permission state, folded into the Access menu. */
  permissionAccess?: ComposerPermissionAccess;
  onModel(modelId: string): void;
  /** A rejected promise (or a throw) means the agent refused the mode: the access chip goes back to the mode in force. */
  onMode(modeId: string): void | Promise<unknown>;
  onEffort(configId: string, value: string): void;
  /// How long a combo must hold before it counts as recent.
  settleMs?: number;
  /// Schedules the settle check and returns its cancel; tests run it by hand.
  settleTimer?: SettleTimer;
  /// Starts a new chat in another harness (the model picker offers it), on `model` when a model
  /// row of that harness was picked: the switch carries it, so the new chat starts on that model
  /// and draws it at once, also before it opens (a New Tab's deferred switch).
  onHarness?(harness: string, model?: string): void;
  /// The folder a pick is remembered for (lastPick.ts), when the chat has none yet (a New Tab's).
  folder?: string;
  /// The pointer or keyboard rests on a harness row (undefined: it left them), for a prewarm hint.
  onHarnessHint?(harness: string | undefined): void;
  /// Enables the chat folder's profile `id` (see ModelPickerProps.onHarnessEnable).
  onHarnessEnable?(folder: string, id: string): void;
  /// Add harness… (see ModelPickerProps.onAddAgent): the picker's last row, and the whole chip
  /// once acpmux has listed no harness at all.
  onAddAgent?(): void;
  /// The harnesses this Mac's acpmux found signed out, and their Log In (see ModelPickerProps.signedOut).
  signIn?: SignIn;
  /// acpmux has answered with its harnesses: only then does an empty catalog mean none is installed.
  harnessesListed?: boolean;
  /// The Plan/Build toggle lives in the composer's + menu in the default pane.
  showPlan?: boolean;
  /** Host-backed catalog refresh; transport stays outside the picker UI. */
  catalogRefresh?: CatalogRefreshState;
  /** Joined host catalog supplied by the app root; direct tests keep using the daemon catalog. */
  pickerCatalog?: PickerCatalog;
  /** A mode pick before the chat has a session is held (a New Tab's start, a harness switch
   * running): only then is a pending chat's start mode a live menu, else an inert chip. */
  holdsModePick?: boolean;
};

export type ComposerPermissionGrant = {
  id: string;
  label: string;
  onRemove(): void;
};

export type ComposerPermissionAccess = {
  grants: readonly ComposerPermissionGrant[];
};

/// The composer bar's controls after the + button: the model chip (its tooltip says how much of
/// the context window the chat has used), effort, the permission mode (in the warning color when
/// it skips approvals) and a Plan/Build toggle. Each control shows only when the agent offers it.
/// The row draws no context ring (hq#1957 item 15 compact row): the running state shows on
/// Send/Stop alone.
export function ComposerPickers({
  snapshot,
  permissionAccess,
  onModel,
  onMode,
  onEffort,
  onHarness,
  onHarnessHint,
  onHarnessEnable,
  onAddAgent,
  signIn,
  harnessesListed = false,
  folder,
  settleMs = RECENT_SETTLE_MS,
  settleTimer = browserSettleTimer,
  showPlan = true,
  catalogRefresh,
  pickerCatalog,
  holdsModePick = false,
}: Props) {
  const t = useT();
  // Context usage rides on the model chip's tooltip, unless the person hid it (composerSettings.ts);
  // the reasoning menu draws a slider when the person opted in (the Debug Settings toggle agent.reasoningSlider).
  const { showContextUsage, reasoningSlider, reasoningSliderStyle, modelMenu, harnessSwitch } = useComposerSettings();
  // The compact model menu carries Effort and Account, so the row has no effort chip of its own.
  const compact = modelMenu === "compact";
  const chatAccounts = useChatAccounts();
  const summary = snapshot.summary;
  // The rail lists the harnesses set up here (Leo 2026-10-11): one whose launcher check failed (not
  // installed, not signed in) stays behind the rail's +, unless this chat runs it. A failed model
  // probe alone (a timeout) keeps it.
  // Once a chat has a message its harness is fixed (Leo 2026-10-13): the picker lists that
  // harness's models only, with no harness rail and no Add harness… (Leo 2026-10-19: a rail of one
  // harness, then Add harness…, read as an offer to switch), and another harness is Continue in…,
  // never a pick. Debug Settings' "Allow switching harness in a started chat" (`harnessSwitch`)
  // keeps the whole rail and its switch.
  const locked = !harnessSwitch && !!summary?.harness && ((summary.turnCount ?? 0) > 0 || snapshot.rows.length > 0);
  const allEntries: ModelPickerProps["catalog"] = pickerCatalog
    ? [
        ...pickerCatalog.harnesses
          .filter(
            (entry) =>
              !entry.unavailable || entry.probeFailed || (entry.acpmuxHarness ?? entry.id) === summary?.harness,
          )
          .map((entry) => ({
            id: entry.acpmuxHarness ?? entry.id,
            name: entry.name,
            models: entry.models,
            ...(entry.unavailable ? { unavailable: entry.unavailable } : {}),
            pickable: entry.pickable && entry.acpmuxHarness !== null,
            ...(topModelsFor(entry.id) ? { top: topModelsFor(entry.id) } : {}),
          })),
        // The chat folder's own profiles are acpmux's alone; the model catalog never lists them.
        ...snapshot.catalog.filter((entry) => entry.folder),
      ]
    : snapshot.catalog;
  // A harness acpmux has not listed yet (the first open after launch) keeps the whole list rather
  // than an empty picker.
  const ownEntries = locked ? allEntries.filter((entry) => entry.id === summary?.harness) : [];
  const pickerEntries = ownEntries.length > 0 ? ownEntries : allEntries;
  const switchHarness = locked ? undefined : onHarness;
  // An agent's own default remains an internal sentinel. The picker omits it
  // instead of exposing a separate "Default" row.
  const models: Choice[] = sessionModels(snapshot.catalog, summary);
  const allModes: Choice[] = (summary?.modes?.availableModes ?? []).map((mode) => ({
    id: mode.id,
    name: mode.name || mode.id,
    description: mode.description,
  }));
  const plan = allModes.find((choice) => isPlan(choice.id));
  const modes = allModes.filter((choice) => choice !== plan);
  const hasGrants = (permissionAccess?.grants.length ?? 0) > 0;
  const currentId = summary?.modes?.currentModeId;
  const planning = plan !== undefined && currentId === plan.id;
  // Leaving Plan returns to the permission mode this session had before it, never another session's.
  const lastMode = useRef<{ sessionId?: string; mode?: string }>({});
  if (lastMode.current.sessionId !== summary?.sessionId) lastMode.current = { sessionId: summary?.sessionId };
  if (currentId && !planning) lastMode.current.mode = currentId;
  const mode = modes.find((choice) => choice.id === (planning ? lastMode.current.mode : currentId));
  const effort = summary?.configOptions?.find(isEffortOption);
  // The running model's catalog row (live list_models / model/list when known): which levels it
  // supports and which one is its own default. A chat on the agent's default model is described
  // by the model that default resolved to.
  const runningModel =
    summary?.model && isDefaultChoice({ id: summary.model })
      ? (resolvedModel(summary) ?? (summary.harness ? loadResolvedDefaults()[summary.harness] : undefined))
      : summary?.model;
  const catalogModel = catalogRow(
    pickerCatalog?.harnesses.find((entry) => entry.acpmuxHarness === summary?.harness || entry.id === summary?.harness)
      ?.models,
    runningModel,
  );
  const efforts: Choice[] = reasoningChoices(effort?.options ?? [], catalogModel, t);
  // Claude Code's Ultracode: a switch beside the levels, offered where the model runs Extra High.
  // It rides the free effort option (ultracode on, Extra High off): acpmux's own `ultracode` id is a
  // mode switch the app would confirm with a sheet.
  const ultracodeOption = summary?.configOptions?.find((option) => option.id === "ultracode");
  const ultracode: SpeedSection | undefined =
    ultracodeOption && efforts.some((choice) => choice.id === "xhigh")
      ? {
          title: t("effort.level.ultracode"),
          choices: [
            { id: "on", name: t("picker.on"), description: t("effort.ultracodeDetail") },
            { id: "off", name: t("picker.off") },
          ],
          current: ultracodeOption.currentValue,
          on: "on",
          onPick: (value) => onEffort(effort?.id ?? "effort", value === "on" ? "ultracode" : "xhigh"),
        }
      : undefined;
  const fastOption = snapshot.summary?.configOptions?.find(
    (option) => option.id === "fast-mode" || /fast[ _-]?mode/i.test(option.name ?? ""),
  );
  const fastOn =
    fastOption?.options.find((option) => /^(on|true|enabled)$/i.test(option.value)) ?? fastOption?.options[1];
  const fastOff =
    fastOption?.options.find((option) => /^(off|false|disabled)$/i.test(option.value)) ?? fastOption?.options[0];
  const fastMode =
    fastOption && fastOn && fastOff && fastOn.value !== fastOff.value
      ? {
          name: fastOption.name ?? t("picker.fastModeSection"),
          currentValue: fastOption.currentValue,
          onValue: fastOn.value,
          offValue: fastOff.value,
          onLabel: fastOn.name ?? fastOn.value,
          offLabel: fastOff.name ?? fastOff.value,
          onPick: (value: string) => onEffort(fastOption.id, value),
        }
      : undefined;
  // The bolt left of the mic (FastToggle.tsx): every tier the option offers past off, where the
  // running model honors fast mode (as the menu's speed section), or while a tier is still on.
  const speedTiers: SpeedTiers | undefined =
    fastOption && fastMode && (catalogModel?.fast !== false || fastMode.currentValue !== fastMode.offValue)
      ? {
          current: fastOption.currentValue,
          off: fastMode.offValue,
          tiers: fastOption.options.map((option) => option.value).filter((value) => value !== fastMode.offValue),
          onPick: fastMode.onPick,
        }
      : undefined;
  useSpeedToggle(speedTiers);
  const model = models.find((choice) => choice.id === summary?.model);
  const effortName = efforts.find((choice) => choice.id === effort?.currentValue)?.name;
  // Recents follow what the session actually runs, whichever control changed it,
  // once it settles: a switch passes through the new model with the old effort.
  const [recents, setRecents] = useState(loadRecents);
  const harness = summary?.harness;
  // The chip draws a pick at once; the combo sequencing and the recents follow what the agent
  // reports (`confirmedModel`, set while a pick is unconfirmed).
  const shown = summary?.model;
  const current = summary?.confirmedModel ?? shown;
  const currentEffort = effort?.currentValue;
  const offersEffort = effort !== undefined;
  // A harness still starting reports nothing yet: what it draws is not a combo the viewer used.
  const switching = snapshot.switching !== undefined;
  useEffect(() => {
    if (switching || !harness || !current || (offersEffort && !currentEffort)) return;
    return settleTimer(
      () =>
        setRecents((list) =>
          rememberCombo(list, { harness, model: current, effort: currentEffort, effortName: effortName }),
        ),
      settleMs,
    );
  }, [switching, harness, current, currentEffort, offersEffort, effortName, settleMs, settleTimer]);
  // A combo for another model sends the model first, then its effort once the
  // agent reports that model and offers the effort; anything else drops it.
  const pending = useRef<
    { sessionId?: string; from?: string; model: string; effort: string; reached?: boolean } | undefined
  >(undefined);
  const effortId = effort?.id;
  const effortValues = (effort?.options ?? []).map((option) => option.value).join("\u0000");
  useEffect(() => {
    const wanted = pending.current;
    if (!wanted) return;
    // Dropped on a session switch, or once the session moves off the picked model (or never reaches it).
    const away = current !== wanted.model && (current !== wanted.from || wanted.reached);
    if (wanted.sessionId !== summary?.sessionId || away) {
      pending.current = undefined;
      return;
    }
    if (current === wanted.model) wanted.reached = true;
    if (current !== wanted.model || !effortId || !effortValues.split("\u0000").includes(wanted.effort)) return;
    pending.current = undefined;
    if (wanted.effort !== currentEffort) onEffort(effortId, wanted.effort);
  }, [summary?.sessionId, current, currentEffort, effortId, effortValues, onEffort]);
  // One pick of a model and effort: the model first, then the effort once the agent reports
  // that model offering it (the effect above); the same model only changes the effort.
  // A pick in a chat on another machine names that machine's models: this one's new chats keep theirs.
  const remembers = !summary?.host && summary?.hostKind !== "cloud";
  const land = (pickedModel: string, pickedEffort?: string) => {
    // Any new pick replaces a combo still waiting on its effort.
    pending.current = undefined;
    if (harness && remembers) rememberPick({ harness, model: pickedModel }, folder ?? summary?.cwd);
    if (pickedModel !== shown) {
      pending.current = pickedEffort
        ? { sessionId: summary?.sessionId, from: current, model: pickedModel, effort: pickedEffort }
        : undefined;
      onModel(pickedModel);
    } else if (
      effort &&
      pickedEffort &&
      pickedEffort !== currentEffort &&
      efforts.some((choice) => choice.id === pickedEffort)
    )
      onEffort(effort.id, pickedEffort);
  };
  // A typed combo ("gpt medium fast", ModelPicker): its model and effort land as a pick does, and
  // fast mode turns on once the agent reports the model and offers it. A combo for another harness
  // starts that harness and waits for its new session, then lands the same way. A failed switch,
  // or a session that is not the one the pick started, drops it.
  const crossing = useRef<(ModelCombo & { from?: string }) | undefined>(undefined);
  const fastWanted = useRef<{ sessionId?: string; model: string } | undefined>(undefined);
  const combo = (picked: ModelCombo) => {
    crossing.current = undefined;
    fastWanted.current = undefined;
    if (picked.harness !== harness) {
      if (!switchHarness) return;
      crossing.current = { ...picked, from: summary?.sessionId };
      if (remembers) rememberPick({ harness: picked.harness, model: picked.model }, folder ?? summary?.cwd);
      switchHarness(picked.harness, picked.model);
      return;
    }
    land(picked.model, picked.effort);
    if (!picked.fast) return;
    // The model already runs: fast mode changes now; else once the agent reports the model.
    if (picked.model === current && fastMode) {
      if (fastMode.currentValue !== fastMode.onValue) fastMode.onPick(fastMode.onValue);
    } else fastWanted.current = { sessionId: summary?.sessionId, model: picked.model };
  };
  const switchFailed = snapshot.switching?.phase === "failed";
  useEffect(() => {
    const wanted = crossing.current;
    if (!wanted) return;
    if (switchFailed) {
      crossing.current = undefined;
      return;
    }
    if (switching || !summary?.sessionId || summary.sessionId === wanted.from || harness !== wanted.harness) return;
    crossing.current = undefined;
    // The switch already sent the model: only its effort remains, now when the agent runs that
    // model (its default, or it reported the switch first), else once it reports it.
    pending.current = undefined;
    if (wanted.effort && current === wanted.model) {
      if (effort && wanted.effort !== currentEffort && efforts.some((choice) => choice.id === wanted.effort))
        onEffort(effort.id, wanted.effort);
    } else if (wanted.effort)
      pending.current = { sessionId: summary.sessionId, from: current, model: wanted.model, effort: wanted.effort };
    if (wanted.fast) fastWanted.current = { sessionId: summary.sessionId, model: wanted.model };
  });
  const fastValue = fastMode?.currentValue;
  useEffect(() => {
    const wanted = fastWanted.current;
    if (!wanted) return;
    if (wanted.sessionId !== summary?.sessionId) {
      fastWanted.current = undefined;
      return;
    }
    if (current !== wanted.model || !fastMode) return;
    fastWanted.current = undefined;
    if (fastValue !== fastMode.onValue) fastMode.onPick(fastMode.onValue);
  });
  // A default model draws as the model it resolves to: the running session's, else the one this
  // harness's default last resolved to, else the model placeholder.
  // The model a New Tab starts a chat on `agent` with (newTabStart, newTabChipSnapshot): the last
  // pick here, else its profile's, else its first listed model, else the catalog's default.
  const startingModel = (agent: string) => {
    const entry = pickerCatalog?.harnesses.find((candidate) => (candidate.acpmuxHarness ?? candidate.id) === agent);
    const asked = defaultModel(agent, snapshot.catalog, harnessProfiles, folder ?? summary?.cwd);
    const id = asked && !isDefaultChoice({ id: asked }) ? asked : entry?.defaultModel;
    if (!id || isDefaultChoice({ id })) return undefined;
    return (
      entry?.models.find((choice) => choice.id === id)?.name ??
      models.find((choice) => choice.id === id)?.name ??
      modelIdName(id, t)
    );
  };
  const defaulted = shown !== undefined && isDefaultChoice(model ?? { id: shown });
  // A harness still starting draws its last session's options, which name no model this chat runs.
  const resolvedNow = switching ? undefined : resolvedModel(summary);
  useEffect(() => {
    if (harness && resolvedNow) rememberResolvedDefault(harness, resolvedNow);
  }, [harness, resolvedNow]);
  // A new chat draws its chips for the harness its first prompt starts: the one named, else the
  // catalog's first, as the model picker's face does.
  const chipHarness = harness ?? pickerEntries[0]?.id;
  const unreported = shown === undefined && chipHarness !== undefined && (!summary?.sessionId || switching);
  // A fresh chat on this Mac whose session has not reported its model yet names the one its New Tab
  // started it on (cx-e2aa, cx-21jvw). A resumed or remote chat may run another: it waits.
  const fresh = (summary?.turnCount ?? 0) === 0 && !summary?.host && summary?.hostKind !== "cloud";
  // Before a fresh chat's session reports, the default this harness last resolved to, else the model
  // catalog's default for it, else the first model it lists (defaultModel: its last session's).
  const predictedId =
    unreported && fresh
      ? (loadResolvedDefaults()[chipHarness] ??
        pickerCatalog?.harnesses.find((entry) => (entry.acpmuxHarness ?? entry.id) === chipHarness)?.defaultModel ??
        defaultModel(chipHarness, snapshot.catalog))
      : undefined;
  const resolvedId = unreported
    ? predictedId
    : defaulted
      ? (resolvedNow ?? (harness ? loadResolvedDefaults()[harness] : undefined))
      : undefined;
  const resolvedName =
    resolvedId &&
    (models.find((choice) => choice.id === resolvedId && !isDefaultChoice(choice))?.name ??
      snapshot.catalog
        .find((entry) => entry.id === chipHarness)
        ?.models.find((choice) => choice.id === resolvedId && !isDefaultChoice(choice))?.name ??
      modelIdName(resolvedId, t));
  // A New Tab's chat names the model it will start on (the last pick here), not the default's last
  // resolution: no other model first (Leo 2026-10-13: "Claude Sonnet 5", then his Opus 5.5).
  const starting = shown === undefined && chipHarness && fresh && !switching ? startingModel(chipHarness) : undefined;
  // Before the session reports, the predicted model's name holds the chip's width (cx-ncc.58).
  const modelName =
    defaulted || unreported
      ? (starting ?? resolvedName ?? t(PICKER_LABELS.model))
      : (model?.name ?? summary?.model ?? starting);
  // Until the session reports its options (a new chat, an agent still starting), the effort chip
  // draws what this harness's chats last showed (chipMemory.ts) and the access chip acpmux's
  // start-mode answer (startMode.ts), never grey bars; the session's values then replace them in
  // place (cx-ncc.58, Leo 2026-10-13).
  const awaiting =
    chipHarness !== undefined && (!summary?.sessionId || (switching && snapshot.switching?.phase !== "failed"));
  // The agent's own level ("default") names the level it resolves to: the running model's default
  // effort. Unresolved, the chip says Reasoning; it never guesses the first level.
  const effortDefaulted = effort?.currentValue === "default";
  const effortValue = effort && (effortDefaulted ? catalogModel?.defaultEffort : effort.currentValue);
  const effortChoice = efforts.find((choice) => choice.id === effortValue);
  const ultracodeOn = ultracode !== undefined && ultracode.current === ultracode.on;
  const effortLabel =
    effort && efforts.length > 1
      ? ultracodeOn
        ? t("effort.level.ultracode")
        : (effortChoice?.name ?? t("picker.reasoning"))
      : undefined;
  // An unresolved level is not remembered: the next chat would paint it as a pick.
  const effortShown = effortChoice || ultracodeOn ? effortLabel : undefined;
  const lastChips = awaiting && chipHarness ? loadLastChips()[chipHarness] : undefined;
  // A harness no chat has shown here yet (a fresh profile, the New Tab's first chat) names the
  // level acpmux starts it on (`_acpmux/harnesses` start), so Reasoning never goes missing.
  const startEffort = awaiting ? snapshot.catalog.find((entry) => entry.id === chipHarness)?.start?.effort : undefined;
  const startEffortKey = startEffort ? LEVEL_KEYS[startEffort] : undefined;
  const pendingEffort = lastChips?.effort ?? (startEffortKey ? t(startEffortKey) : undefined);
  // Before the session reports its effort option (a New Tab, a new chat, a harness still
  // starting), Reasoning is still its own control, never a picture of one (P0 #8): its levels are
  // the ones this harness's last session offered (harnessProfiles.ts), else the chip model's
  // catalog levels under acpmux's generic `effort` id, which acpmux resolves to the harness's own
  // option (model_options.rs). A pick goes through `onEffort` as a reported option's does, and the
  // pane holds it for the session the pick starts (harnessSwitch.ts pickConfig).
  const [heldPick, setHeldPick] = useState<{ harness: string; value: string }>();
  useEffect(() => {
    if (!awaiting) setHeldPick(undefined);
  }, [awaiting]);
  const reported = effort !== undefined && efforts.length > 1;
  const heldOption =
    !reported && awaiting ? harnessProfiles.get(chipHarness)?.configOptions?.find(isEffortOption) : undefined;
  const heldModel =
    !reported && awaiting
      ? (catalogModel ??
        catalogRow(
          pickerCatalog?.harnesses.find((entry) => (entry.acpmuxHarness ?? entry.id) === chipHarness)?.models,
          shown ?? predictedId,
        ))
      : undefined;
  const heldLevels =
    !reported && awaiting
      ? reasoningChoices(heldOption?.options ?? (heldModel?.efforts ?? []).map((value) => ({ value })), heldModel, t)
      : [];
  const heldValue =
    (heldPick?.harness === chipHarness ? heldPick.value : undefined) ??
    startEffort ??
    heldLevels.find((choice) => choice.name === lastChips?.effort)?.id ??
    heldOption?.currentValue;
  // The held chip steps down as the reported one does: "Med" in a narrow row (composerRowFit.ts).
  const heldChoice = heldLevels.find((choice) => choice.id === heldValue);
  const heldShort = heldChoice && heldChoice.id !== "ultracode" ? shortLevel(heldChoice, t) : undefined;
  // Before a chat reports its modes, the access chip names the mode acpmux answers it will start
  // the chat in (`_acpmux/start_mode`: its kept answer on the first frame, then the one asked for),
  // never the mode this harness's last chat showed; nothing when it sets none. A chat on another
  // machine (a peer, the cloud) starts in what that machine decides: none until it reports.
  const local = fresh && snapshot.origin !== "remote" && snapshot.origin !== "peer";
  const startMode = useStartMode(chipHarness, folder ?? summary?.cwd, awaiting && local && modes.length === 0);
  // Another folder's answer (acpmux has not answered for this one yet) only holds the chip's
  // place: this folder's profile or preset may start the chat in another mode, so it names none.
  const startModeName = startMode?.borrowed
    ? t(PICKER_LABELS.mode)
    : startMode
      ? (startMode.name ??
        harnessProfiles.get(chipHarness)?.modes?.availableModes.find((choice) => choice.id === startMode.modeId)
          ?.name ??
        startMode.modeId)
      : undefined;
  // Until the chat reports its modes, the start mode acpmux answered is a live menu (not an inert
  // chip) where a pick is held (`holdsModePick`): the harness's last mode catalog for the rows,
  // checked at the start mode, never at the mode its last chat showed, and named as acpmux named
  // it. A start in Plan keeps the inert chip: Plan is never an access row.
  const pendingAccessModes: Choice[] = (() => {
    if (!holdsModePick || !startMode || startMode.borrowed || isPlan(startMode.modeId)) return [];
    const known = (harnessProfiles.get(chipHarness)?.modes?.availableModes ?? [])
      .filter((choice) => !isPlan(choice.id))
      .map((choice) => ({
        id: choice.id,
        name: (choice.id === startMode.modeId ? startMode.name : undefined) || choice.name || choice.id,
        description: choice.description,
      }));
    if (known.some((choice) => choice.id === startMode.modeId)) return known;
    const description = unrestricted(startMode.modeId) ? t(PICKER_LABELS.fullAccessWarning) : undefined;
    return [{ id: startMode.modeId, name: startModeName ?? startMode.modeId, description }, ...known];
  })();
  useEffect(() => {
    if (!awaiting && chipHarness && summary?.sessionId && effortShown)
      rememberLastChips(chipHarness, { effort: effortShown });
  }, [awaiting, chipHarness, summary?.sessionId, effortShown]);
  // The controls row's short forms (composerRowFit.ts): the model's name without its vendor
  // ("Opus 5.5": the catalog's short name, else the name less its harness's vendor word), its
  // family for a narrow row ("Opus"), and the effort level's short name ("Med").
  const chipEntry = pickerCatalog?.harnesses.find((entry) => (entry.acpmuxHarness ?? entry.id) === chipHarness);
  const modelShort = modelName
    ? shortModelName(
        modelName,
        chipEntry?.models.find((choice) => choice.name === modelName)?.shortName,
        chipEntry?.name ?? snapshot.catalog.find((entry) => entry.id === chipHarness)?.name,
      )
    : undefined;
  const modelShown = modelShort ?? modelName;
  const familyShown = modelFamily(modelShown ?? "");
  const modelChip = modelName
    ? {
        ...(modelShort ? { short: modelShort } : {}),
        ...(familyShown ? { family: familyShown } : {}),
        title: modelName,
      }
    : undefined;
  const effortShort = !ultracodeOn && effortChoice ? shortLevel(effortChoice, t) : undefined;
  // The compact menu's Effort rows: the reported levels (Ultracode last, where the model offers it),
  // else the held ones before the session reports, picked the same way as their chips pick them.
  const quickEffort: QuickMenuExtras["effort"] =
    effort && efforts.length > 1
      ? {
          levels: ultracode ? [...efforts, { id: "ultracode", name: ultracode.title }] : efforts,
          current: ultracodeOn ? "ultracode" : effortValue,
          onPick: (value) => {
            pending.current = undefined;
            onEffort(effort.id, value);
          },
        }
      : heldLevels.length > 1 && chipHarness
        ? {
            levels: heldLevels,
            current: heldValue,
            onPick: (value) => {
              pending.current = undefined;
              setHeldPick({ harness: chipHarness, value });
              onEffort(heldOption?.id ?? "effort", value);
            },
          }
        : undefined;
  // Accounts are this Mac's acpmux routes: a chat on another machine has none here.
  const quickAccount: QuickMenuExtras["account"] =
    chatAccounts && summary?.sessionId && !summary.host && summary.hostKind !== "cloud"
      ? { sessionId: summary.sessionId, accounts: chatAccounts }
      : undefined;
  // Fast mode rides the Effort submenu as it rides the reasoning menu: the bolt leaves narrow rows.
  const quickSpeed =
    fastMode && fastOn && fastOff && (catalogModel?.fast !== false || fastMode.currentValue === fastMode.onValue)
      ? speedSection(/codex/i.test(summary?.harness ?? ""), fastMode, fastOn, t)
      : undefined;
  const quick: QuickMenuExtras | undefined = compact
    ? {
        ...(quickEffort ? { effort: { ...quickEffort, ...(quickSpeed ? { speed: quickSpeed } : {}) } } : {}),
        ...(quickAccount ? { account: quickAccount } : {}),
      }
    : undefined;
  // The compact chip names the effort after the model ("Opus 5.5 Medium"), and its short name for a
  // narrow row ("Med"). Before the session reports, it names the held pick, as the held chip did.
  const quickDetail = compact
    ? (effortLabel ?? (awaiting ? (heldChoice?.name ?? pendingEffort) : undefined))
    : undefined;
  const quickShort = compact ? (effortLabel ? effortShort : awaiting ? heldShort : undefined) : undefined;
  const usage = summary?.usage;
  const usageNote =
    showContextUsage && usage && usage.size > 0
      ? t(PICKER_LABELS.context, { percent: Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) })
      : undefined;

  const chips = (
    <div className="acpmux-chips">
      {snapshot.catalog.length > 0 || harness || Boolean(pickerCatalog?.harnesses.length && !harnessesListed) ? (
        <ModelPicker
          catalog={pickerEntries}
          harness={harness}
          model={shown}
          label={modelName ?? t(PICKER_LABELS.model)}
          {...(modelChip ? { chip: modelChip } : {})}
          switching={snapshot.switching?.phase === "failed" ? undefined : snapshot.switching}
          efforts={efforts}
          effort={currentEffort}
          recents={recents}
          onLand={(pickedModel) => land(pickedModel)}
          onEffort={(value) => {
            pending.current = undefined;
            if (effort) onEffort(effort.id, value);
          }}
          onHarness={switchHarness}
          onCombo={combo}
          onHarnessHint={onHarnessHint}
          onHarnessEnable={onHarnessEnable}
          onAddAgent={onAddAgent}
          harnessFixed={locked}
          {...(signIn ? { signedOut: pickableSignedOut(signIn.signedOut, summary), onLogIn: signIn.logIn } : {})}
          fastMode={fastMode}
          catalogRefresh={catalogRefresh}
          harnessNotes={
            snapshot.switching?.phase === "failed"
              ? { [snapshot.switching.harness]: t("switch.failedShort") }
              : undefined
          }
          usage={usageNote}
          {...(quick ? { quick } : {})}
          {...(quickDetail ? { detail: quickDetail } : {})}
          {...(quickShort && quickShort !== quickDetail ? { detailShort: quickShort } : {})}
        />
      ) : (
        // No harness installed (Leo 2026-10-14): the chip itself adds one, a plain button styled as
        // the model chip, with no menu and no chevron. Before acpmux answers, nothing shows.
        harnessesListed &&
        onAddAgent && (
          <span className="acpmux-picker acpmux-model">
            <button type="button" className="acpmux-picker-button acpmux-add-harness" onClick={onAddAgent}>
              <span className="acpmux-model-name">{t("composer.addHarness")}</span>
            </button>
          </span>
        )
      )}
      {/* Reasoning is its own stable control, separate from the model and harness picker. A model
          whose only level is the agent's default has nothing to pick, so it shows no control. */}
      {!compact && effort && efforts.length > 1 && (
        <EffortPicker
          label={t(PICKER_LABELS.effort)}
          efforts={efforts}
          current={effortValue}
          defaulted={effortDefaulted}
          ultracode={ultracode}
          {...(effortShort ? { short: effortShort } : {})}
          speed={
            // Fast mode only where the running model honors it (Claude Code offers it on every model).
            fastMode &&
            fastOn &&
            fastOff &&
            (catalogModel?.fast !== false || fastMode.currentValue === fastMode.onValue)
              ? speedSection(/codex/i.test(summary?.harness ?? ""), fastMode, fastOn, t)
              : undefined
          }
          chevron={<ChevronIcon />}
          slider={reasoningSlider}
          sliderStyle={reasoningSliderStyle}
          onPick={(value) => {
            pending.current = undefined;
            onEffort(effort.id, value);
          }}
        />
      )}
      {compact ? null : heldLevels.length > 1 && chipHarness && pendingEffort ? (
        <EffortPicker
          label={t(PICKER_LABELS.effort)}
          efforts={heldLevels}
          current={heldValue}
          {...(heldShort ? { short: heldShort } : {})}
          chevron={<ChevronIcon />}
          onPick={(value) => {
            pending.current = undefined;
            setHeldPick({ harness: chipHarness, value });
            onEffort(heldOption?.id ?? "effort", value);
          }}
        />
      ) : (
        !reported && pendingEffort && <PendingChip kind="effort" label={pendingEffort} />
      )}
      {modes.length === 0 && !hasGrants && startMode && startModeName && pendingAccessModes.length === 0 && (
        <PendingChip kind="mode" label={startModeName} modeId={startMode.borrowed ? undefined : startMode.modeId} />
      )}
      {/* Granted folder trust and chat allowance stay revocable when the harness offers no modes. */}
      {(modes.length > 0 || hasGrants || pendingAccessModes.length > 0) && (
        <AccessMenu
          label={t(PICKER_LABELS.mode)}
          modes={modes.length > 0 ? modes : pendingAccessModes}
          current={mode?.id ?? (pendingAccessModes.length > 0 ? startMode?.modeId : undefined)}
          sessionId={summary?.sessionId}
          warning={t(PICKER_LABELS.fullAccessWarning)}
          help={t(PICKER_LABELS.modeHelp)}
          refusedReason={t(PICKER_LABELS.modeRefused)}
          permissionAccess={permissionAccess}
          onMode={onMode}
        />
      )}
      {showPlan && plan && (
        // Its right-click menu names both modes; the current one is disabled (cx-2lm4).
        <ContextMenu
          className="acpmux-plan-menu"
          items={[
            {
              id: "plan",
              label: t(PICKER_LABELS.plan),
              disabled: planning,
              onSelect: () => void settle(() => onMode(plan.id)),
            },
            {
              id: "build",
              label: t(PICKER_LABELS.build),
              disabled: !planning,
              onSelect: () => void settle(() => onMode(lastMode.current.mode ?? modes[0]?.id ?? plan.id)),
            },
          ]}
        >
          <button
            type="button"
            className="acpmux-plan"
            aria-pressed={planning}
            onClick={() => onMode(planning ? (lastMode.current.mode ?? modes[0]?.id ?? plan.id) : plan.id)}
          >
            {planning ? <PlanIcon /> : <BuildIcon />}
            <span>{planning ? t(PICKER_LABELS.plan) : t(PICKER_LABELS.build)}</span>
          </button>
        </ContextMenu>
      )}
    </div>
  );
  return chips;
}

/// A control the session has not reported yet, as this harness's chats last showed it: the real
/// chip's face (EffortPicker, AccessMenu), inert until the session's own replaces it in place.
/// `modeId` is read from storage: only a string names a mode that may skip approvals.
function PendingChip({ kind, label, modeId }: { kind: "effort" | "mode"; label: string; modeId?: unknown }) {
  const t = useT();
  const short = kind === "effort" ? shortLevelName(label, t) : label;
  const warning = typeof modeId === "string" && unrestricted(modeId) ? " acpmux-unrestricted" : "";
  return kind === "effort" ? (
    <span className="acpmux-picker acpmux-effort acpmux-chip-pending" aria-hidden="true">
      <span className="acpmux-picker-button">
        <EffortLabel label={label} short={short !== label ? short : undefined} />
        <ChevronIcon />
      </span>
    </span>
  ) : (
    <span className={`acpmux-mode acpmux-access acpmux-chip-pending${warning}`} aria-hidden="true">
      <span className="acpmux-picker-button acpmux-access-trigger">
        <ModeShield modeId={modeId} />
        <span className="acpmux-mode-text" data-fit-part="access" data-fit-forms="full">
          {label}
        </span>
        <ChevronIcon />
      </span>
    </span>
  );
}

/** The permission control stays quiet in the footer: the mode's shield names the control (a lock
 * when the harness offers no modes and only grants remain) and the menu carries the mode title
 * and one-line explanation, each row with its own shield. Base UI owns focus, typeahead and Escape. */
/// Runs a mode pick; resolves false when the agent refused it (a rejected promise or a throw).
function settle(run: () => void | Promise<unknown>): Promise<boolean> {
  try {
    return Promise.resolve(run()).then(
      () => true,
      () => false,
    );
  } catch {
    return Promise.resolve(false);
  }
}

function AccessMenu({
  label,
  modes,
  current,
  sessionId,
  warning,
  help,
  refusedReason,
  permissionAccess,
  onMode,
}: {
  label: string;
  modes: Choice[];
  current?: string;
  sessionId?: string;
  warning: string;
  help: string;
  refusedReason: string;
  permissionAccess?: ComposerPermissionAccess;
  onMode(modeId: string): void | Promise<unknown>;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  // Right-click and automation open it by its label (pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  const [optimistic, setOptimistic] = useState<{ sessionId?: string; modeId: string }>();
  useEffect(() => {
    if (optimistic && optimistic.sessionId !== sessionId) setOptimistic(undefined);
  }, [optimistic, sessionId]);
  useEffect(() => {
    if (optimistic?.sessionId === sessionId && optimistic?.modeId === current) setOptimistic(undefined);
  }, [current, optimistic, sessionId]);
  const optimisticMode = optimistic?.sessionId === sessionId ? optimistic?.modeId : undefined;
  // Modes the agent refused in this session (a company-managed Mac's Claude Code settings can
  // disable bypass mode): the chip goes back to the mode in force and their rows are disabled.
  const [refused, setRefused] = useState<{ sessionId?: string; ids: readonly string[] }>({ ids: [] });
  const refusedIds = refused.sessionId === sessionId ? refused.ids : [];
  // A chat that has not reported its mode (one acpmux has not started) names none, not the first,
  // and every mode, the first included, is a pick.
  const value = optimisticMode ?? current ?? "";
  const currentMode = modes.find((choice) => choice.id === value);
  const grants = permissionAccess?.grants ?? [];
  const pick = (next: string) => {
    if (refusedIds.includes(next)) return;
    setOptimistic({ sessionId, modeId: next });
    setOpen(false);
    void settle(() => onMode(next)).then((applied) => {
      if (applied) return;
      setOptimistic((pending) => (pending?.modeId === next ? undefined : pending));
      setRefused((old) => ({
        sessionId,
        ids: [...(old.sessionId === sessionId ? old.ids : []), next],
      }));
    });
  };
  const tooltip = `${label}: ${currentMode?.name ?? label}\n${help}`;
  // Nothing left to pick (every other mode refused, no grants): a plain label, never a dead menu.
  if (
    refusedIds.length > 0 &&
    grants.length === 0 &&
    modes.every((choice) => choice.id === value || refusedIds.includes(choice.id))
  ) {
    return (
      <span
        className={`acpmux-mode acpmux-access acpmux-access-fixed${unrestricted(value) ? " acpmux-unrestricted" : ""}`}
        data-fit-title={currentMode?.name ?? label}
        data-fit-title-unit="access"
        /* tooltip-allow: the chip is its shield alone; the tooltip says what it is and why it is fixed */
        title={`${tooltip}\n${refusedReason}`}
      >
        <ModeShield modeId={value} />
        <span className="acpmux-mode-text" data-fit-part="access" data-fit-forms="full">
          {currentMode?.name ?? label}
        </span>
      </span>
    );
  }
  return (
    <span
      className={`acpmux-mode acpmux-access${unrestricted(value) ? " acpmux-unrestricted" : ""}`}
      // A narrow row shows the glyph alone; the row's fit names the mode in a tooltip then (composerRowFit.ts).
      data-fit-title={currentMode?.name ?? label}
      data-fit-title-unit="access"
    >
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton
          className="acpmux-picker-button acpmux-access-trigger"
          label={label}
          /* tooltip-allow: the chip is its shield alone; the tooltip names the mode and what the control is */
          title={tooltip}
          aria-haspopup="menu"
        >
          {modes.length > 0 ? <ModeShield modeId={value} /> : <LockIcon />}
          <span className="acpmux-mode-text" data-fit-part="access" data-fit-forms="full">
            {currentMode?.name ?? (modes.length === 0 ? grants[0]?.label : undefined) ?? label}
          </span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup
          side="top"
          align="start"
          className="acpmux-access-menu"
          // ui-allow: 1 to 9 pick the mode in that place while the menu is open, as in Claude's mode menu.
          onKeyDown={(event) => {
            if (event.metaKey || event.ctrlKey || event.altKey || !/^[1-9]$/.test(event.key)) return;
            const choice = modes[Number(event.key) - 1];
            if (!choice) return;
            event.preventDefault();
            if (choice.id === value) setOpen(false);
            else pick(choice.id);
          }}
        >
          {modes.length > 0 && (
            <MenuRadioGroup value={value} onValueChange={pick}>
              {modes.map((choice, index) => (
                <MenuRadioItem
                  key={choice.id}
                  value={choice.id}
                  disabled={refusedIds.includes(choice.id)}
                  shortcut={index < 9 ? String(index + 1) : undefined}
                  className={`acpmux-access-item${unrestricted(choice.id) ? " acpmux-unrestricted" : ""}`}
                >
                  <span className="acpmux-access-item-icon" aria-hidden="true">
                    {choice.icon ?? <ModeShield modeId={choice.id} />}
                  </span>
                  <span className="acpmux-menu-text">
                    <span className="acpmux-menu-label">{choice.name}</span>
                    {refusedIds.includes(choice.id) ? (
                      <span className="acpmux-menu-description">{refusedReason}</span>
                    ) : choice.description || unrestricted(choice.id) ? (
                      <span className="acpmux-menu-description">{choice.description ?? warning}</span>
                    ) : null}
                  </span>
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          )}
          {grants.length > 0 && (
            <fieldset className="acpmux-access-grants" aria-label={t("permission.grants")}>
              <div className="acpmux-access-grants-heading">{t("permission.grants")}</div>
              {grants.map((grant) => (
                <div className="acpmux-access-grant" key={grant.id}>
                  <span className="acpmux-access-grant-label">{grant.label}</span>
                  <button
                    type="button"
                    className="acpmux-access-grant-remove"
                    aria-label={`${t("permission.revoke")}: ${grant.label}`}
                    onClick={grant.onRemove}
                  >
                    ×
                  </button>
                </div>
              ))}
            </fieldset>
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// Plan modes (an id ending in "plan") read and propose without editing; the toggle sits apart from the permission chip.
export function isPlan(modeId: string): boolean {
  return /(^|[-_])plan$/i.test(modeId);
}

/// How much of the context window the session has used, as a pie that fills. A click opens
/// the details: the share used, tokens used of the window, and Compact when the agent offers it.
export function ContextRing({
  used,
  size,
  setup,
  onCompact,
  working = false,
}: {
  used?: number;
  size?: number;
  /// Tokens the agent took before the conversation; the details split it out when known.
  setup?: number;
  onCompact?(): void;
  working?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  // Whether the details were open when a press on the ring began. That press is also the
  // popover's outside press, which can close it before the click lands; the click then
  // toggles from the state the press saw, so the press that closed it does not reopen it.
  const openAtPress = useRef<boolean | null>(null);
  const known = used !== undefined && size !== undefined && size > 0;
  const fraction = known ? Math.min(1, Math.max(0, used / size)) : 0;
  const percent = Math.round(fraction * 100);
  const label = known ? t(PICKER_LABELS.context, { percent }) : t("context.title");
  // A 1px track ring, and the share used as a filled wedge inside it (a pie, not a spinner):
  // a circle stroked as wide as its diameter, dashed to the share, with butt ends.
  const wedgeRadius = 2.75;
  const wedgeCircumference = 2 * Math.PI * wedgeRadius;
  useEffect(() => {
    // Keep the automation path truthful too: before the first usage report the ring is
    // intentionally inert, so opening it by label must not reveal an empty 0% popover.
    const unregister = registerPicker(t("context.title"), () => {
      if (known) setOpen(true);
    });
    return unregister;
  }, [known, t]);
  useEffect(() => {
    // Usage can disappear when a session resets. Do not leave an already-open details
    // surface showing a stale zeroed reading.
    if (!known) setOpen(false);
  }, [known]);
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const full = fraction >= 0.8 ? " acpmux-context-full" : "";
  return (
    <span className={`acpmux-picker acpmux-context${full}`}>
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-ring"
        data-menu={t("context.title")}
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        // Before the first usage report there is nothing to show: the ring keeps its place, off.
        disabled={!known}
        onPointerDown={() => (openAtPress.current = open)}
        onClick={() => {
          setOpen(!(openAtPress.current ?? open));
          openAtPress.current = null;
        }}
      >
        <svg width={16} height={16} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
          <circle cx="8" cy="8" r={7} fill="none" stroke="currentColor" strokeOpacity={0.35} strokeWidth={1} />
          {fraction >= 1 ? (
            <circle cx="8" cy="8" r={wedgeRadius * 2} fill="currentColor" />
          ) : (
            fraction > 0 && (
              <circle
                cx="8"
                cy="8"
                r={wedgeRadius}
                fill="none"
                stroke="currentColor"
                strokeWidth={wedgeRadius * 2}
                strokeLinecap="butt"
                strokeDasharray={`${wedgeCircumference * fraction} ${wedgeCircumference}`}
                transform="rotate(-90 8 8)"
              />
            )
          )}
        </svg>
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={open ? trigger.current : null}
        label={t("context.title")}
        className={`acpmux-context-pop${full}`}
        finalFocus={trigger}
      >
        <div className="acpmux-context-title">{t("context.title")}</div>
        <div className="acpmux-context-percent">{t("context.percent", { percent })}</div>
        <div className="acpmux-context-bar" aria-hidden="true">
          <span style={{ width: `${percent}%` }} />
        </div>
        {known && (
          <div className="acpmux-context-tokens">
            {t("context.tokens", { used: tokens.format(used), size: tokens.format(size) })}
          </div>
        )}
        {known && setup !== undefined && setup <= used && (
          <div className="acpmux-context-parts">
            <div className="acpmux-context-part">
              <span className="acpmux-context-part-name">{t("context.setup")}</span>
              <span className="acpmux-context-part-tokens">{tokens.format(setup)}</span>
              <span className="acpmux-context-part-detail">{t("context.setupDetail")}</span>
            </div>
            <div className="acpmux-context-part">
              <span className="acpmux-context-part-name">{t("context.conversation")}</span>
              <span className="acpmux-context-part-tokens">{tokens.format(used - setup)}</span>
            </div>
          </div>
        )}
        {onCompact && (
          <button
            type="button"
            className="acpmux-context-compact"
            disabled={working}
            onClick={() => {
              setOpen(false);
              onCompact();
            }}
          >
            {t("context.compact")}
          </button>
        )}
      </Popover>
    </span>
  );
}

/// Modes that skip approvals (such as "Full access") draw in the theme's warning color.
export function unrestricted(modeId: string): boolean {
  return /bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(modeId);
}

/// A pick that returns "keep" leaves the menu open (e.g. a row that expands the menu).
export type Section = { title?: string; choices: Choice[]; current?: string; onPick(id: string): void | "keep" };

/// A button that opens a menu above the composer: a select-only combobox, so
/// focus stays on the button, which names the active option. Each section is
/// a group with a check on its current choice; arrows move, Enter, Space or a
/// click picks, and Escape, a click elsewhere or focus leaving the pane closes.
export function Picker({
  label,
  className,
  button,
  sections,
  align,
  warnUnrestricted = false,
  returnFocus = true,
  heading,
}: {
  label: string;
  className: string;
  button: React.ReactNode;
  sections: Section[];
  align: "start" | "end";
  warnUnrestricted?: boolean;
  /// An action menu hands focus to whatever its pick focuses, not back to the button.
  returnFocus?: boolean;
  /// A question over the choices, as an approval menu asks it.
  heading?: string;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement | null>(null);
  const menuId = useId();
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  // No room above or below its button in the pane: past the window's edge (popupHost.ts).
  const host = usePopupHost();
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host],
  );
  useEscapingPopup(host, shown, () => trigger.current, {
    side: "top",
    align,
    gap: UI_ANCHOR_GAP,
    kind: "list",
    active: ".acpmux-menu-active",
  });
  const rows = sections.flatMap((section, s) => section.choices.map((choice) => ({ section: s, choice })));
  // A live update can shrink the list under the highlight.
  const selected = Math.min(active, Math.max(rows.length - 1, 0));

  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const blur = () => setOpen(false);
    // In the capture phase, as Base UI's menus close: a press outside only closes the menu, and
    // nothing under it sees the press (menuPressGuard.ts).
    document.addEventListener("pointerdown", away, true);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away, true);
      window.removeEventListener("blur", blur);
    };
  }, [open]);

  // A mouse press is opening it (cg-composer click polish): the focus it moves here is not drawn.
  const byPointer = useRef(false);
  const show = () => {
    const current = rows.findIndex((row) => row.choice.id === sections[row.section].current);
    setActive(Math.max(current, 0));
    setOpen(true);
    // WebKit doesn't focus a clicked button; the keys must reach the menu, not the prompt. After a
    // key was typed WebKit draws a programmatic focus as keyboard focus, so a press says it is not.
    focusWithRing(trigger.current, byPointer.current ? { focusVisible: false } : undefined);
  };
  const showRef = useRef(show);
  showRef.current = show;
  // Like a click, which takes focus off the prompt first: that closes the slash menu and restores the draft.
  useEffect(
    () =>
      registerPicker(label, () => {
        if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
        showRef.current();
      }),
    [label],
  );
  const close = () => {
    setOpen(false);
    trigger.current?.focus();
  };
  const press = usePopoverTrigger(open, setOpen, show);
  const pick = (index: number) => {
    const row = rows[index];
    if (!row) return;
    if (sections[row.section].onPick(row.choice.id) === "keep") return;
    if (returnFocus) close();
    else setOpen(false);
  };
  const keyDown = (event: React.KeyboardEvent) => {
    if (!open) {
      if (event.key === "ArrowUp" || event.key === "ArrowDown") {
        event.preventDefault();
        show();
      }
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      // Back on the button with its ring, though a press opened the menu without one: the button
      // already has the focus, so it takes it again (escapeFocus.ts).
      trigger.current?.blur();
      focusAfterEscape(trigger.current);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      if (rows.length > 0) setActive((selected + step + rows.length) % rows.length);
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      if (rows.length > 0) setActive(event.key === "Home" ? 0 : rows.length - 1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(selected);
    }
    // A button clicks on Space's keyup; pick there and cancel that click, or it would reopen the menu.
    else if (event.key === " ") event.preventDefault();
    else if (event.key === "Tab") setOpen(false);
  };
  const keyUp = (event: React.KeyboardEvent) => {
    if (open && event.key === " ") {
      event.preventDefault();
      pick(selected);
    }
  };

  let index = -1;
  return (
    <span
      ref={root}
      className={`acpmux-picker ${className}`}
      style={{ position: "relative" }}
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) setOpen(false);
      }}
    >
      <button
        ref={trigger}
        type="button"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="combobox"
        className="acpmux-picker-button"
        data-menu={label}
        aria-label={label}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-activedescendant={open && rows.length > 0 ? `${menuId}-${selected}` : undefined}
        onKeyDown={keyDown}
        onKeyUp={keyUp}
        {...press}
        onPointerDown={(event) => {
          byPointer.current = isMousePress(event);
          press.onPointerDown(event);
          byPointer.current = false;
        }}
      >
        {button}
      </button>
      {/* A native select cannot hold descriptions, sections or the pane's styling. */}
      {open && (
        <div ref={attach} style={menuStyle} className={`ui-popup acpmux-menu acpmux-menu-${align}`} data-side="above">
          {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
          <div id={menuId} role="listbox" aria-label={heading ?? label}>
            {heading && (
              <div className="acpmux-menu-heading" aria-hidden="true">
                {heading}
              </div>
            )}
            {sections.map((section, s) => {
              const titled = section.title && sections.length > 1;
              return (
                <div
                  key={s}
                  className="acpmux-menu-section"
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                  role="group"
                  aria-labelledby={titled ? `${menuId}-group-${s}` : undefined}
                  aria-label={titled ? undefined : label}
                >
                  {titled && (
                    <div className="acpmux-menu-header" id={`${menuId}-group-${s}`}>
                      {section.title}
                    </div>
                  )}
                  {section.choices.map((choice) => {
                    index += 1;
                    const at = index;
                    const current = choice.id === section.current;
                    return (
                      <div
                        key={choice.id}
                        id={`${menuId}-${at}`}
                        data-value={choice.id}
                        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                        role="option"
                        tabIndex={-1}
                        // `aria-selected` is the option's value; the combobox's
                        // `aria-activedescendant` carries the keyboard highlight.
                        aria-selected={section.current === undefined ? false : current}
                        className={`acpmux-menu-item${at === selected ? " acpmux-menu-active" : ""}${warnUnrestricted && unrestricted(choice.id) ? " acpmux-unrestricted" : ""}`}
                        onMouseMove={() => {
                          if (at !== selected) setActive(at);
                        }}
                        onMouseDown={(event) => {
                          event.preventDefault();
                          pick(at);
                        }}
                      >
                        {choice.icon}
                        <span className="acpmux-menu-text">
                          <span className="acpmux-menu-label">{choice.name}</span>
                          {choice.description && <span className="acpmux-menu-description">{choice.description}</span>}
                        </span>
                        {choice.hint && <kbd className="acpmux-menu-hint">{choice.hint}</kbd>}
                        {current && <CheckIcon />}
                      </div>
                    );
                  })}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </span>
  );
}

// Composer icons (a 16px grid drawn at 18px, stroke in currentColor).
function Icon({ children, size = 18, shield }: { children: React.ReactNode; size?: number; shield?: string }) {
  return (
    <svg
      className="acpmux-icon"
      data-shield={shield}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}
const SHIELD = "M8 1.9 13 3.7v4.1c0 3.1-2.3 5.3-5 6.3-2.7-1-5-3.2-5-6.3V3.7Z";
/** Full access: the shield with an exclamation mark, drawn in the warning color by its row. */
export const ShieldIcon = ({ shield }: { shield?: string }) => (
  <Icon shield={shield}>
    <path d={SHIELD} />
    <path d="M8 5.2v3.3" />
    <circle cx="8" cy="10.9" r=".35" fill="currentColor" />
  </Icon>
);
/** A mode that asks first (Claude's default and plan, Codex read-only): the shield with a check. */
const ShieldCheckIcon = ({ shield }: { shield?: string }) => (
  <Icon shield={shield}>
    <path d={SHIELD} />
    <path d="m5.9 8.1 1.5 1.5 2.8-2.9" />
  </Icon>
);
/** A mode that acts without asking within its limits (accept edits, Codex auto, Claude's don't
 * ask): the plain shield. */
const ShieldPlainIcon = ({ shield }: { shield?: string }) => (
  <Icon shield={shield}>
    <path d={SHIELD} />
  </Icon>
);
export const LockIcon = () => (
  <Icon>
    <rect x="3.5" y="7" width="9" height="7" rx="1.5" />
    <path d="M5.5 7V5.6a2.5 2.5 0 0 1 5 0V7" />
  </Icon>
);
/** One shield family for the permission mode, the same on the trigger and in the menu: the mark
 * inside the shield carries the risk (compact-composer verdict, 2026-10-14). The svg itself
 * carries data-shield, with no wrapper: it stays the trigger's first child, as the lock was, so
 * the trailing-chevron rules (`.acpmux-icon:last-child`) never restyle it. */
function ModeShield({ modeId }: { modeId?: unknown }) {
  const kind =
    typeof modeId !== "string"
      ? "plain"
      : unrestricted(modeId)
        ? "alert"
        : /accept|auto|dont[-_ ]?ask/i.test(modeId)
          ? "plain"
          : "check";
  return kind === "alert" ? (
    <ShieldIcon shield={kind} />
  ) : kind === "check" ? (
    <ShieldCheckIcon shield={kind} />
  ) : (
    <ShieldPlainIcon shield={kind} />
  );
}
export const ChevronIcon = () => (
  <Icon size={14}>
    <path d="M4.6 6.3 8 9.6l3.4-3.3" />
  </Icon>
);
export const ChevronRightIcon = () => (
  <Icon>
    <path d="m6.25 4.25 3.5 3.75-3.5 3.75" />
  </Icon>
);
/// 16px in the model menu's search; the + menu draws it at its items' 18px.
export const SearchIcon = ({ size = 16 }: { size?: number }) => (
  <Icon size={size}>
    <circle cx="7" cy="7" r="4.25" />
    <path d="m10.25 10.25 3 3" />
  </Icon>
);
export const CheckIcon = () => (
  <Icon>
    <path d="M3 8.6 6.3 12 13 4.5" />
  </Icon>
);
export const PlusIcon = () => (
  <Icon>
    <path d="M8 2.75v10.5M2.75 8h10.5" />
  </Icon>
);
/** Send's arrow: iMessage's bold arrow.up, a heavier stroke than the bar's other glyphs. */
export const ArrowUpIcon = () => (
  <Icon>
    <path d="M8 12.9V3.4M3.9 7.5 8 3.4l4.1 4.1" strokeWidth={2.1} />
  </Icon>
);
export const StopIcon = () => (
  <svg className="acpmux-icon" width={18} height={18} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
    <rect x="3" y="3" width="10" height="10" rx="2" fill="currentColor" />
  </svg>
);
export const PlanIcon = () => (
  <Icon>
    <path d="M5.5 4.25h7.25M5.5 8h7.25M5.5 11.75h7.25" />
    <circle cx="3" cy="4.25" r=".6" fill="currentColor" />
    <circle cx="3" cy="8" r=".6" fill="currentColor" />
    <circle cx="3" cy="11.75" r=".6" fill="currentColor" />
  </Icon>
);
export const BuildIcon = () => (
  <Icon>
    <path d="m9.6 3.2 3.2 3.2-6.9 6.9H2.7V10.1Z" />
    <path d="m8.2 4.6 3.2 3.2" />
  </Icon>
);
export const PaperclipIcon = () => (
  <Icon>
    <path d="m13.1 7.6-5 5a3.2 3.2 0 0 1-4.5-4.5l5.3-5.3a2.1 2.1 0 0 1 3 3L6.6 11a1.05 1.05 0 0 1-1.5-1.5L10 4.6" />
  </Icon>
);
export const AtIcon = () => (
  <Icon>
    <circle cx="8" cy="8" r="2.4" />
    <path d="M10.4 8v.9a1.8 1.8 0 0 0 3.6 0V8A6 6 0 1 0 11 13.2" />
  </Icon>
);
export const MicIcon = () => (
  <Icon>
    <rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" />
    <path d="M3 7.5a5 5 0 0 0 10 0M8 12.5V15" />
  </Icon>
);
export const SlashIcon = () => (
  <Icon>
    <path d="M10.5 2.5 5.5 13.5" />
  </Icon>
);

/// Level names the pane writes itself, whatever the agent calls them ("Xhigh" reads Extra High).
/// The signed-out harnesses the picker blocks: never the one a started chat runs on, whose session
/// already signed in (a stale or wrong health row must not lock the person out of their chat).
function pickableSignedOut(
  signedOut: Readonly<Record<string, string>>,
  summary: AcpmuxSnapshot["summary"],
): Readonly<Record<string, string>> {
  const running = summary?.sessionId ? summary.harness : undefined;
  if (!running || !(running in signedOut)) return signedOut;
  const { [running]: _running, ...rest } = signedOut;
  return rest;
}

const LEVEL_KEYS: Record<string, StringKey> = {
  low: "effort.level.low",
  medium: "effort.level.medium",
  high: "effort.level.high",
  xhigh: "effort.level.xhigh",
  max: "effort.level.max",
  ultra: "effort.level.ultra",
  // A new chat that starts on Ultracode (its saved pick); never a level row (reasoningChoices).
  ultracode: "effort.level.ultracode",
};
/// A level's short name in a narrow controls row: "Med" for Medium.
const SHORT_LEVEL_KEYS: Record<string, StringKey> = {
  low: "effort.short.low",
  medium: "effort.short.medium",
  high: "effort.short.high",
  xhigh: "effort.short.xhigh",
  max: "effort.short.max",
};

/// The short name of a level the pane names `name` ("Medium" -> "Med"); `name` when it is no level.
function shortLevelName(name: string, t: (key: StringKey) => string): string {
  const id = Object.keys(SHORT_LEVEL_KEYS).find((level) => LEVEL_KEYS[level] && t(LEVEL_KEYS[level]!) === name);
  return id ? t(SHORT_LEVEL_KEYS[id]!) : name;
}

/// A level's short name for a narrow controls row, whole words only: its own ("Med" for Medium),
/// else, for a level of several words ("Medium Fast"), its first word's ("Med"). Undefined when the
/// level has none shorter than its name.
function shortLevel(choice: Choice, t: (key: StringKey) => string): string | undefined {
  const key = SHORT_LEVEL_KEYS[choice.id];
  if (key) return t(key);
  const first = choice.name.trim().split(/\s+/)[0] ?? "";
  if (first.length < 3 || first === choice.name.trim()) return undefined;
  return shortLevelName(first, t);
}

/// A model's name without its vendor, for the controls row: `short`, the catalog's own short
/// name, when the name ends with it ("Claude Opus 5.5" -> "Opus 5.5"), else the name less a first
/// word its harness's name starts with ("Claude" of "Claude Code", "Gemini" of "Gemini CLI").
/// Undefined when there is nothing to drop.
export function shortModelName(name: string, short?: string, harnessName?: string): string | undefined {
  const trimmed = short?.trim();
  if (trimmed && trimmed.length < name.length && name.endsWith(` ${trimmed}`)) return trimmed;
  const vendor = harnessName?.trim().split(/\s+/)[0];
  const space = name.indexOf(" ");
  if (!vendor || space <= 0) return undefined;
  const rest = name.slice(space + 1).trim();
  return rest && name.slice(0, space).toLowerCase() === vendor.toLowerCase() ? rest : undefined;
}

/// A model's family for a narrow controls row: its name's first word ("Opus" of "Opus 5.5") when
/// that word is a name of at least 3 letters and not the whole name. Undefined otherwise.
export function modelFamily(name: string): string | undefined {
  const first = name.trim().split(/\s+/)[0] ?? "";
  return first !== name.trim() && /\p{L}{3,}/u.test(first) ? first : undefined;
}

/// The session's reasoning option, whatever the harness calls it.
function isEffortOption(option: { id: string; category?: string | null }): boolean {
  return option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort";
}

/// The plain levels a catalog row can list (`PickerModel.efforts`).
const PLAIN_LEVELS = new Set(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]);

/// The Reasoning section's rows: the agent's levels, named by the pane, narrowed to what the
/// running model supports when its catalog row says. The agent-owned default sentinel is omitted,
/// and so are an older acpmux's Ultracode (now its own switch) and Ultrathink (a prompt keyword,
/// not a level).
export function reasoningChoices(
  options: { value: string; name?: string; description?: string }[],
  model: { efforts?: readonly string[]; defaultEffort?: string } | undefined,
  t: (key: StringKey) => string,
): Choice[] {
  const levels = model?.efforts && model.efforts.length > 0 ? new Set<string>(model.efforts) : undefined;
  const offered = options.filter((option) => {
    if (["default", "ultracode", "ultrathink"].includes(option.value)) return false;
    if (!levels) return true;
    return !PLAIN_LEVELS.has(option.value) || levels.has(option.value);
  });
  return offered.map((option) => {
    const key = LEVEL_KEYS[option.value];
    const base: Choice = { id: option.value, name: key ? t(key) : option.name || option.value };
    if (option.value === model?.defaultEffort) base.recommended = true;
    return base;
  });
}

/// The menu's speed section: Codex calls fast mode a Service Tier (Standard, the default, or
/// Fast with Codex's own description); Claude Code's is Fast Mode, On or Off.
function speedSection(
  codex: boolean,
  fast: { currentValue?: string; onValue: string; offValue: string; onPick(value: string): void },
  on: { description?: string },
  t: (key: StringKey) => string,
): SpeedSection {
  return codex
    ? {
        title: t("picker.serviceTier"),
        choices: [
          { id: fast.offValue, name: t("picker.tierStandard") },
          { id: fast.onValue, name: t("picker.tierFast"), description: on.description },
        ],
        current: fast.currentValue,
        on: fast.onValue,
        onPick: fast.onPick,
      }
    : {
        title: t("picker.fastModeSection"),
        choices: [
          { id: fast.onValue, name: t("picker.on") },
          { id: fast.offValue, name: t("picker.off") },
        ],
        current: fast.currentValue,
        on: fast.onValue,
        onPick: fast.onPick,
      };
}
