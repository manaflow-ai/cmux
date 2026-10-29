import React, { useCallback, useContext, useEffect, useId, useRef, useState } from "react";
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
import type { SpeedSection } from "./EffortPicker";
import { pendingSpeed } from "./pendingSpeed";
import { fastModeIsOn, nextFastModeValue } from "./fastModeState";
import { type StringKey, useT } from "./i18n";
import { ModelPicker, pickerFaceHarness } from "./ModelPicker";
import { AgentOptionsMenu } from "./AgentOptionsMenu";
import { OnNewTab } from "./newTabComposer";
import { extraConfigOptions } from "./agentOptions";
import type { CatalogRefreshState, ModelCombo, ModelPickerProps } from "./modelPickerLayout";
import { rememberPick } from "./lastPick";
import { defaultModel } from "./harnessSwitch";
import { catalogRow } from "./catalogRow";
import { harnessProfiles } from "./harnessProfiles";
import {
  HELD_EFFORT_ID,
  HELD_FAST_ID,
  HELD_FAST_ON,
  heldOptionPick,
  isEffortOption,
  isFastModeOption,
} from "./heldOptions";
import {
  type KeptStartMode,
  type StartMode,
  useFullAccessManaged,
  useFullAccessProbe,
  useStartMode,
} from "./startMode";
import type { PickerCatalog } from "./modelCatalogData";
import { catalogProfiles } from "./pickerProfiles";
import { useModelCatalogState } from "./modelCatalogHost";
import { focusWithRing } from "../../ui/focusWithRing";
import { AnchoredCard } from "../../ui/Tooltip";
import { HOVER_INTENT } from "../../ui/hoverIntent";
import { useHoverCard } from "./chips/useHoverCard";
import { ContextCardBody } from "./ContextCard";
import { contextBreakdown } from "./inspector/ContextSection";
import { ContextMenu } from "../../ui/ContextMenu";
import { useComposerSettings } from "./composerSettings";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { registerPicker } from "./pickerOpeners";
import { scrollActiveMenuRow } from "./scrollActiveMenuRow";
import { UI_ANCHOR_GAP, useUiAnchor } from "../../ui/anchor";
import { useEscapingPopup } from "../../ui/popupHost";
import { usePopupHost } from "../../ui/UiProvider";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { isMousePress } from "../../ui/pressRelease";
import { focusAfterEscape } from "../../ui/escapeFocus";
import {
  type ModeIconName,
  RECOMMENDED_BADGE,
  type ShownMode,
  harnessFamilyMenu,
  harnessModeMenu,
  highestMode,
  shownModes,
} from "./harnessModes";

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
  /// A full-access row while MDM or a team policy keeps full access off (#23322).
  fullAccessManaged: "picker.fullAccessManaged",
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

/// A permission mode row: a choice with the harness's own badge and icon (harnessModes.ts).
type ModeChoice = Omit<Choice, "icon"> & Pick<ShownMode, "recommended" | "icon">;

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
  /// and draws it at once, also before it opens (a New Tab's deferred switch). `options`: a typed
  /// combo's effort and Fast, held under their kind's id (heldOptions.ts); the switch applies them
  /// to the new session before its first prompt.
  onHarness?(harness: string, model?: string, options?: Readonly<Record<string, string>>): void;
  /// Forks a started chat into a new chat on another harness (see ModelPickerProps.fork): with it,
  /// a started chat's model menu keeps the whole harness rail, each other harness a Fork to row.
  fork?: { to(harness: string): void; ready: boolean };
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

/// The composer bar's controls after the + button: one model button that names the model and its
/// effort (its tooltip says how much of the context window the chat has used; its menu holds
/// Effort, More models, Account and Fast mode), the permission mode (in the warning color when it
/// skips approvals) and a Plan/Build toggle. Each control shows only when the agent offers it.
/// The row draws no context ring (hq#1957 item 15 compact row): the running state shows on
/// Send/Stop alone.
export function ComposerPickers({
  snapshot,
  permissionAccess,
  onModel,
  onMode,
  onEffort,
  onHarness,
  fork,
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
  const lastFastValue = useRef<{ scope: string; value: string } | undefined>(undefined);
  // Context usage rides on the model chip's tooltip, unless the person hid it (composerSettings.ts).
  // The model button is the row's one model control (Leo 2026-10-20): it names the model and its
  // effort ("Opus 5.5  Medium") and opens the compact menu, which carries Effort, More models,
  // Account and, when the model advertises a free inline toggle, Fast mode. Paid or otherwise
  // non-toggleable Fast remains in the model menu.
  const { showContextUsage, harnessSwitch, reasoningSlider, reasoningSliderStyle } = useComposerSettings();
  const chatAccounts = useChatAccounts();
  const summary = snapshot.summary;
  // The rail lists the harnesses set up here (Leo 2026-10-11): one whose launcher check failed (not
  // installed, not signed in) stays behind the rail's +, unless this chat runs it. A failed model
  // probe alone (a timeout) keeps it.
  // Once a chat has a message its harness is fixed (Leo 2026-10-13): the picker lists that
  // harness's models only, with no harness rail and no Add harness… (Leo 2026-10-19: a rail of one
  // harness, then Add harness…, read as an offer to switch), and another harness is Continue In…,
  // never a pick. Where the chat can fork (`fork`), the compact menu keeps the whole rail again
  // (Leo 2026-10-22: "why did you guys even remove the fucking harness model picker"), its other
  // harnesses Fork to rows. Debug Settings' "Allow switching harness in a started chat"
  // (`harnessSwitch`) keeps the whole rail and its switch.
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
            ...(entry.topModels ? { top: entry.topModels } : {}),
          })),
        // The chat folder's own profiles are acpmux's alone; the model catalog never lists them.
        ...snapshot.catalog.filter((entry) => entry.folder),
      ]
    : snapshot.catalog;
  // A harness acpmux has not listed yet (the first open after launch) keeps the whole list rather
  // than an empty picker. A chat that can fork keeps every harness: the picker offers the others as
  // Fork to, never as a switch in place (Leo 2026-10-22: "can expose as fork").
  const ownEntries = locked && !fork ? allEntries.filter((entry) => entry.id === summary?.harness) : [];
  const pickerEntries = ownEntries.length > 0 ? ownEntries : allEntries;
  // Installed launch configurations are separate from route-backed accounts in the model menu.
  const profiles = pickerCatalog ? catalogProfiles(snapshot.catalog, pickerCatalog.harnesses) : undefined;
  const switchHarness = locked ? undefined : onHarness;
  // An agent's own default remains an internal sentinel. The picker omits it
  // instead of exposing a separate "Default" row.
  const models: Choice[] = sessionModels(snapshot.catalog, summary);
  // The harness's own mode menu (harnessModes.ts): Claude Code's and Codex's labels, descriptions
  // and order for the ids they report; any other harness's modes as it reports them.
  const modeMenu = harnessModeMenu(
    summary?.family,
    summary?.harness,
    (summary?.modes?.availableModes ?? []).map((mode) => mode.id),
  );
  const allModes: ModeChoice[] = shownModes(
    modeMenu,
    (summary?.modes?.availableModes ?? []).map((mode) => ({
      id: mode.id,
      name: mode.name || mode.id,
      ...(mode.description ? { description: mode.description } : {}),
    })),
    summary?.modes?.currentModeId,
  );
  // Plan is its own toggle, unless the harness's own menu lists it as a mode (Claude Code's does).
  const plan = modeMenu?.rows.some((row) => isPlan(row.id)) ? undefined : allModes.find((choice) => isPlan(choice.id));
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
  // A profile the catalog does not map to its family (a second Claude account's harness id) still
  // runs a catalogued model: its family's row for that id (else any harness's) names it, so the
  // chips never fall back to the raw id or to the word Reasoning.
  const kinRows = (id = runningModel) =>
    [
      ...(pickerCatalog?.harnesses.filter((entry) => entry.id === summary?.family) ?? []),
      ...(pickerCatalog?.harnesses ?? []),
    ].map((entry) => catalogRow(entry.models, id));
  const ownRow = catalogRow(
    pickerCatalog?.harnesses.find((entry) => entry.acpmuxHarness === summary?.harness || entry.id === summary?.harness)
      ?.models,
    runningModel,
  );
  const catalogModel = ownRow ?? kinRows().find((row) => row !== undefined);
  // The levels the chat runs and the one the agent's "default" resolves to come from this chat's
  // own model row, else from the release it runs (Leo 2026-10-22: "this should just show the effort
  // too right? and then the effort tells you what you're already currrently on?"). A profile's probed
  // row (a claude-sr2 chat's Opus 5.5) names the model but no level; the release's catalog row does.
  // An alias ("opus") is not a release: what it runs depends on the installed harness, so another
  // profile's row for it never lends its levels. Its release is the one its own row names, else
  // acpmux's row for it, else the one the session's model option reports it runs (Claude Code's
  // `opus` running claude-opus-5-5), once no switch or other pick is in flight. A release is an id
  // the model catalog lists as a model; unknown, the button names no level.
  const { catalog: modelCatalog } = useModelCatalogState();
  const isRelease = (id: string | undefined): id is string => {
    const bare = id?.replace(/\[[^\]]*\]$/, "");
    return (
      !!bare &&
      !isDefaultChoice({ id: bare }) &&
      (bare in modelCatalog.models ||
        modelCatalog.harnesses.some((harness) => harness.models.some((model) => model.id === bare)))
    );
  };
  const modelOption = summary?.configOptions?.find((option) => option.category === "model" || option.id === "model");
  // A harness still starting shows its last session's options, which name no model this chat runs.
  const settled =
    snapshot.switching === undefined && (!summary?.confirmedModel || summary.confirmedModel === summary.model);
  const runningRelease = [
    runningModel,
    ownRow?.release,
    snapshot.catalog.find((entry) => entry.id === summary?.harness)?.models.find((row) => row.id === runningModel)
      ?.release,
    settled && typeof modelOption?.currentValue === "string" ? modelOption.currentValue : undefined,
  ].find(isRelease);
  // The release's own row first (a harness that lists it pinned), else a row that stands for it.
  const releaseRows = runningRelease
    ? [
        ...kinRows(runningRelease).filter((row) => row?.id === runningRelease && !row.release),
        ...kinRows(runningRelease),
      ].filter((row) => row !== undefined)
    : [];
  const levelRow = ownRow?.efforts.length ? ownRow : (releaseRows.find((row) => row.efforts.length > 0) ?? ownRow);
  const defaultEffort =
    ownRow?.defaultEffort ?? releaseRows.find((row) => row.defaultEffort !== undefined)?.defaultEffort;
  // A direct profile can declare an alias with `efforts: []` before the joined catalog has retained
  // its `own` marker. Keep that explicit no-level declaration attached to the running release row.
  const profileDeclaresNoEffort =
    (ownRow?.own?.efforts === true && ownRow.efforts.length === 0) ||
    snapshot.catalog
      .find((entry) => entry.id === summary?.harness)
      ?.models.some(
        (model) =>
          model.id === runningModel &&
          Object.hasOwn(model, "efforts") &&
          Array.isArray(model.efforts) &&
          model.efforts.length === 0,
      );
  const efforts: Choice[] = reasoningChoices(
    effort?.options ?? [],
    {
      ...(levelRow ? { efforts: levelRow.efforts } : {}),
      ...(defaultEffort ? { defaultEffort } : {}),
      ...(levelRow?.own?.efforts || profileDeclaresNoEffort ? { own: { efforts: true } } : {}),
      ...(profileDeclaresNoEffort ? { noEffort: true } : {}),
    },
    t,
  );
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
  const fastOption = snapshot.summary?.configOptions?.find(isFastModeOption) ?? pendingSpeed(snapshot, catalogModel);
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
          values: fastOption.options.map((option) => option.value),
          lastOnValue:
            fastOption.currentValue && fastOption.currentValue !== fastOff.value ? fastOption.currentValue : undefined,
          onPick: (value: string) => onEffort(fastOption.id, value),
        }
      : undefined;
  // Fast mode is offered where the running model honors it, or while it is still on.
  const fastOffered =
    fastMode !== undefined && (catalogModel?.fast !== false || fastMode.currentValue !== fastMode.offValue);
  const fastCurrentValue = fastMode?.currentValue;
  const fastOffValue = fastMode?.offValue;
  // Fast mode is a row in the model menu for every harness. The picker owns the toggle;
  // the composer never renders a separate lightning button.
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
  // Before the chat has a session (a New Tab's deferred chat, a harness still starting) the switch
  // holds every pick and applies it before the first prompt (harnessSwitch.ts): a combo's effort and
  // Fast go to it at once, so a prompt sent right after the pick runs on the whole combo. An option
  // the chat shows no row for yet goes under its kind's id, which the switch maps onto the option
  // the session names once it opens (heldOptions.ts), or drops when it offers none.
  const presession = holdsModePick && !summary?.sessionId;
  const land = (pickedModel: string, pickedEffort?: string) => {
    // Any new pick replaces a combo still waiting on its effort.
    pending.current = undefined;
    if (harness && remembers) rememberPick({ harness, model: pickedModel }, folder ?? summary?.cwd);
    if (pickedModel !== shown) {
      pending.current =
        pickedEffort && !presession
          ? { sessionId: summary?.sessionId, from: current, model: pickedModel, effort: pickedEffort }
          : undefined;
      onModel(pickedModel);
      if (pickedEffort && presession) onEffort(effort?.id ?? HELD_EFFORT_ID, pickedEffort);
    } else if (
      pickedEffort &&
      pickedEffort !== currentEffort &&
      (effort ? efforts.some((choice) => choice.id === pickedEffort) : presession)
    )
      onEffort(effort?.id ?? HELD_EFFORT_ID, pickedEffort);
  };
  // A typed combo ("gpt medium fast", ModelPicker): its model and effort land as a pick does, and
  // fast mode turns on once the agent reports the model and offers it. A combo for another harness
  // starts that harness with the whole combo held on the switch (applied before the first prompt),
  // then checks the effort and Fast once its new session opens. A failed switch, or a session that
  // is not the one the pick started, drops it.
  const crossing = useRef<(ModelCombo & { from?: string }) | undefined>(undefined);
  const fastWanted = useRef<{ sessionId?: string; model: string } | undefined>(undefined);
  // A combo's "fast" on the Fast option this chat draws, as the switch maps a held one onto a
  // session (heldOptions.ts): its plain fast tier, never a higher one; none where the option has no
  // such tier (standard and ultrafast only). Every path a combo's Fast takes sends this or nothing.
  const comboFast = fastOption ? heldOptionPick(HELD_FAST_ID, HELD_FAST_ON, [fastOption]) : undefined;
  const combo = (picked: ModelCombo) => {
    crossing.current = undefined;
    fastWanted.current = undefined;
    if (picked.harness !== harness) {
      if (!switchHarness) return;
      crossing.current = { ...picked, from: summary?.sessionId };
      if (remembers) rememberPick({ harness: picked.harness, model: picked.model }, folder ?? summary?.cwd);
      // The effort and Fast ride the switch, so a prompt sent right after the pick (it queues on the
      // switch) runs its first turn on the whole combo; the effect below only fills in what the new
      // session still reports otherwise.
      const held: Record<string, string> = {
        ...(picked.effort ? { [HELD_EFFORT_ID]: picked.effort } : {}),
        ...(picked.fast ? { [HELD_FAST_ID]: HELD_FAST_ON } : {}),
      };
      switchHarness(picked.harness, picked.model, Object.keys(held).length > 0 ? held : undefined);
      return;
    }
    land(picked.model, picked.effort);
    if (!picked.fast) return;
    // The model already runs: fast mode changes now; else once the agent reports the model.
    if (picked.model === current && fastMode) {
      if (comboFast && fastMode.currentValue !== comboFast.value) onEffort(comboFast.configId, comboFast.value);
    } else if (presession)
      // Held as what it means on the option drawn now (a catalog's priority tier, pendingSpeed.ts),
      // else as plain on: the switch maps either onto the names the session reports.
      onEffort(comboFast?.configId ?? fastOption?.id ?? HELD_FAST_ID, comboFast?.value ?? HELD_FAST_ON);
    else fastWanted.current = { sessionId: summary?.sessionId, model: picked.model };
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
    // The switch already sent the model, and the effort and Fast it could resolve against the new
    // session's options: each is sent again only where the session still reports another value
    // (an older acpmux whose attach named no options), now when the agent runs that model (its
    // default, or it reported the switch first), else once it reports it.
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
    if (comboFast && fastValue !== comboFast.value) onEffort(comboFast.configId, comboFast.value);
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
  // picker's first installed, pickable one, the one the model picker's face draws (a bundled
  // harness acpmux does not have can come first in `pickerEntries`); else the catalog's first.
  const chipHarness = harness ?? pickerFaceHarness(pickerEntries) ?? pickerEntries[0]?.id;
  // Preserve an on tier only for this chat and option. ComposerPickers stays mounted when
  // the person switches chats, so a plain/off chat must not inherit another chat's tier.
  const fastScope = `${summary?.sessionId ?? `new:${chipHarness ?? ""}`}\u0000${chipHarness ?? ""}\u0000${fastOption?.id ?? ""}`;
  const rememberedFastValue = lastFastValue.current?.scope === fastScope ? lastFastValue.current.value : undefined;
  useEffect(() => {
    if (fastCurrentValue === undefined || fastCurrentValue === fastOffValue) return;
    lastFastValue.current = { scope: fastScope, value: fastCurrentValue };
  }, [fastScope, fastCurrentValue, fastOffValue]);
  const chipEntry = pickerCatalog?.harnesses.find((entry) => (entry.acpmuxHarness ?? entry.id) === chipHarness);
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
  // A reported model is named as people say it, never by its raw id (Leo 2026-10-20: the chip read
  // "claude-opus-5-5", a profile that lists models without names): the model catalog's row (from
  // any harness, catalogModel), else the session's own name when that is more than its id, else a
  // name read off the id ("Opus 5.5").
  const ownName = model?.name && model.name !== model.id ? model.name : undefined;
  const runningName = shown
    ? // Only the exact row: "claude-opus-5-5[1m]" keeps its wide-context name (modelIdName).
      ((catalogModel?.id === shown || catalogModel?.release === shown ? catalogModel?.name : undefined) ??
      ownName ??
      modelIdName(shown, t))
    : undefined;
  // Before the session reports, the predicted model's name holds the chip's width (cx-ncc.58).
  const modelName =
    defaulted || unreported ? (starting ?? resolvedName ?? t(PICKER_LABELS.model)) : (runningName ?? starting);
  // Until the session reports its options (a new chat, an agent still starting), the effort chip
  // draws what this harness's chats last showed (chipMemory.ts) and the access chip acpmux's
  // start-mode answer (startMode.ts), never grey bars; the session's values then replace them in
  // place (cx-ncc.58, Leo 2026-10-13).
  const awaiting =
    chipHarness !== undefined && (!summary?.sessionId || (switching && snapshot.switching?.phase !== "failed"));
  // The agent's own level ("default") names the level it resolves to: the running model's default
  // effort. It never guesses the first level.
  const effortDefaulted = effort?.currentValue === "default";
  const effortValue = effort && (effortDefaulted ? defaultEffort : effort.currentValue);
  const effortChoice = efforts.find((choice) => choice.id === effortValue);
  const ultracodeOn = ultracode !== undefined && ultracode.current === ultracode.on;
  const lastChips = awaiting && chipHarness ? loadLastChips()[chipHarness] : undefined;
  // A harness no chat has shown here yet (a fresh profile, the New Tab's first chat) names the
  // level acpmux starts it on (`_acpmux/harnesses` start).
  const startEffort = awaiting ? snapshot.catalog.find((entry) => entry.id === chipHarness)?.start?.effort : undefined;
  const startEffortKey = startEffort ? LEVEL_KEYS[startEffort] : undefined;
  const pendingEffort = lastChips?.effort ?? (startEffortKey ? t(startEffortKey) : undefined);
  // The button names a level, never the word Reasoning (Leo 2026-10-20): the listed level, else the
  // level the effort value is (one the model's row does not list), else what this harness's chats
  // last showed, else the level acpmux starts it on. Unknown, the button names the model alone.
  const effortLabel =
    effort && efforts.length > 1
      ? ultracodeOn
        ? t("effort.level.ultracode")
        : (effortChoice?.name ?? levelName(effort.options, effortValue, t) ?? pendingEffort)
      : undefined;
  // An unresolved level is not remembered: the next chat would paint it as a pick.
  const effortShown = effortChoice || ultracodeOn ? effortLabel : undefined;
  // Before the session reports its effort option (a New Tab, a new chat, a harness still
  // starting), the menu's Effort is still a live pick, never a picture of one (P0 #8): its levels are
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
  // With nothing kept or answered yet (the launch's first page), the chip model's own default level:
  // what acpmux starts the chat on when no setting names one (its curated catalog's default for the
  // model, hub/start_defaults.rs), so the chip names it from the first frame and acpmux's answer
  // replaces it only when it differs (Lucas 2026-10-24).
  const heldValue =
    (heldPick?.harness === chipHarness ? heldPick.value : undefined) ??
    startEffort ??
    heldLevels.find((choice) => choice.name === lastChips?.effort)?.id ??
    heldOption?.currentValue ??
    (snapshot.catalog.length === 0
      ? heldLevels.find((choice) => choice.id === heldModel?.defaultEffort)?.id
      : undefined);
  // The held chip steps down as the reported one does: "Med" in a narrow row (composerRowFit.ts).
  const heldChoice = heldLevels.find((choice) => choice.id === heldValue);
  const heldShort = heldChoice && heldChoice.id !== "ultracode" ? shortLevel(heldChoice, t) : undefined;
  // Before a chat reports its modes, the access chip names the mode acpmux answers it will start
  // the chat in (`_acpmux/start_mode`: its kept answer on the first frame, then the one asked for),
  // never the mode this harness's last chat showed; nothing when it sets none. A chat on another
  // machine (a peer, the cloud) starts in what that machine decides: none until it reports.
  const local = fresh && snapshot.origin !== "remote" && snapshot.origin !== "peer";
  const asksStart = awaiting && local && modes.length === 0;
  const startAnswer = useStartMode(chipHarness, folder ?? summary?.cwd, asksStart);
  // A chat this Mac's acpmux runs: not a peer's, a remote host's or the cloud's. A peer's chat comes
  // over this Mac's own connection; its summary or its listed row names the peer (the attach's
  // detail names none: server/peer_forward.rs adds `peer` to the reply, not to the session).
  const listedPeer = summary?.sessionId
    ? snapshot.sessions.find((session) => session.sessionId === summary.sessionId)?.peer
    : undefined;
  const onThisMac =
    snapshot.origin !== "remote" &&
    snapshot.origin !== "peer" &&
    !summary?.peer &&
    !listedPeer &&
    !summary?.host &&
    summary?.hostKind !== "cloud";
  // A local chat whose menu has a full-access row learns whether full access is managed off, and
  // again on `_acpmux/start_mode_changed` (#23322).
  // The Options chip's choices count too: a harness can offer full access only as a config option
  // (review 48).
  const extraOptions = extraConfigOptions(summary);
  useFullAccessProbe(
    chipHarness,
    folder ?? summary?.cwd,
    !asksStart &&
      onThisMac &&
      (modes.some((choice) => unrestricted(choice.id)) ||
        extraOptions.some((option) => option.options.some((choice) => unrestricted(choice.value)))),
  );
  // This Mac's daemon said full access is managed off: it bounds only the chats it runs (review 37).
  const fullAccessManaged = useFullAccessManaged() && onThisMac;
  // Before acpmux has ever answered for this harness here (a first New Tab), the chip names the
  // harness's highest permission level, the level acpmux starts a chat in when the person chose
  // none (hub/start_mode.rs); acpmux's answer, which carries a saved choice, then replaces it.
  const highest =
    asksStart && startAnswer === undefined
      ? highestMode(summary?.family ?? snapshot.catalog.find((entry) => entry.id === chipHarness)?.family, chipHarness)
      : undefined;
  // The access chip holds its place from the first frame of a chat that has not reported its modes
  // (Leo 2026-10-23, the New Tab: "why is this thing still not showing on the very beginning ... It
  // keeps switching around"): with no mode to name (acpmux sets none, has not answered, or the
  // chat is another machine's) it is the inert "Mode" chip, which the session's own replaces in
  // place, so nothing in the row moves when the harness, its model or its modes arrive.
  const startMode: KeptStartMode | undefined =
    startAnswer ??
    (highest ? { modeId: highest.id, name: highest.name } : undefined) ??
    (awaiting && modes.length === 0 ? MODE_PLACEHOLDER : undefined);
  // Another folder's answer (acpmux has not answered for this one yet) only holds the chip's
  // place: this folder's profile or preset may start the chat in another mode, so it names none.
  // The harness's own menu names the start mode as it names the mode once the chat reports it.
  const pendingMenu =
    modeMenu ??
    harnessModeMenu(undefined, chipHarness, [
      ...(harnessProfiles.get(chipHarness)?.modes?.availableModes ?? []).map((choice) => choice.id),
      ...(startMode && !startMode.borrowed ? [startMode.modeId] : []),
    ]);
  // The chip names a mode whenever one is likely, not a bare "Mode" (Lucas 2026-10-24: "always
  // show the bypass permissions or whatever the mode is meant to be"): another folder's answer names
  // its mode until this folder's own replaces it in place. "Mode" stays for acpmux answering that it
  // sets none here (the harness's own mode applies) and for a chat on another machine.
  const shownStart: StartMode | undefined = startMode?.borrowed
    ? startMode.modeId
      ? startMode
      : undefined
    : startMode;
  const startModeName = shownStart
    ? (pendingMenu?.rows.find((row) => row.id === shownStart.modeId)?.name ??
      shownStart.name ??
      harnessProfiles.get(chipHarness)?.modes?.availableModes.find((choice) => choice.id === shownStart.modeId)?.name ??
      shownStart.modeId)
    : startMode
      ? t(PICKER_LABELS.mode)
      : undefined;
  // The start mode the chip names: none for the "Mode" placeholder or another folder's answer.
  const namedStart = startMode && !startMode.borrowed ? startMode : undefined;
  // Until the chat reports its modes, the access chip is a live menu (not an inert chip) where a
  // pick is held (`holdsModePick`): the harness's last mode catalog for the rows (else its family's
  // own menu), checked at the start mode acpmux answered, never at the mode its last chat showed,
  // and named as acpmux named it. With no start mode to name (acpmux sets none, has not answered
  // for this folder) it checks none and says "Mode", still a pick (Lucas 2026-10-24: a New Tab's
  // "Mode" chip had a chevron but no menu). A start in Plan keeps the inert chip: Plan is never an
  // access row.
  const pendingAccessModes: ModeChoice[] = (() => {
    if (!holdsModePick || !startMode || (namedStart && isPlan(namedStart.modeId))) return [];
    const menu =
      pendingMenu ??
      harnessFamilyMenu(
        summary?.family ?? snapshot.catalog.find((entry) => entry.id === chipHarness)?.family,
        chipHarness,
      );
    const profileModes = harnessProfiles.get(chipHarness)?.modes?.availableModes ?? [];
    const rows: readonly { id: string; name?: string; description?: string }[] =
      profileModes.length > 0 ? profileModes : (menu?.rows ?? []);
    const known = shownModes(
      menu,
      rows
        .filter((choice) => !isPlan(choice.id))
        .map((choice) => ({
          id: choice.id,
          name: (choice.id === namedStart?.modeId ? namedStart.name : undefined) || choice.name || choice.id,
          ...(choice.description ? { description: choice.description } : {}),
        })),
      namedStart?.modeId,
    );
    if (!namedStart || known.some((choice) => choice.id === namedStart.modeId)) return known;
    const description = unrestricted(namedStart.modeId) ? t(PICKER_LABELS.fullAccessWarning) : undefined;
    return [{ id: namedStart.modeId, name: startModeName ?? namedStart.modeId, description }, ...known];
  })();
  useEffect(() => {
    if (!awaiting && chipHarness && summary?.sessionId && effortShown)
      rememberLastChips(chipHarness, { effort: effortShown });
  }, [awaiting, chipHarness, summary?.sessionId, effortShown]);
  // The controls row's short forms (composerRowFit.ts): the model's name without its vendor
  // ("Opus 5.5": the catalog's short name, else the name less its harness's vendor word), its
  // family for a narrow row ("Opus"), and the effort level's short name ("Med").
  const modelShort = modelName
    ? shortModelName(
        modelName,
        (catalogModel?.name === modelName ? catalogModel?.shortName : undefined) ??
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
  const effortShort = ultracodeOn
    ? undefined
    : effortChoice
      ? shortLevel(effortChoice, t)
      : effortLabel && shortLevelName(effortLabel, t);
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
          ...(reasoningSlider ? { slider: true, sliderStyle: reasoningSliderStyle } : {}),
        }
      : heldLevels.length > 1 && chipHarness && !profileDeclaresNoEffort
        ? {
            levels: heldLevels,
            current: heldValue,
            onPick: (value) => {
              pending.current = undefined;
              setHeldPick({ harness: chipHarness, value });
              onEffort(heldOption?.id ?? "effort", value);
            },
            ...(reasoningSlider ? { slider: true, sliderStyle: reasoningSliderStyle } : {}),
          }
        : undefined;
  // Accounts are this Mac's acpmux routes: a chat on another machine has none here.
  const quickAccount: QuickMenuExtras["account"] =
    chatAccounts && summary?.sessionId && !summary.host && summary.hostKind !== "cloud"
      ? { sessionId: summary.sessionId, accounts: chatAccounts }
      : undefined;
  // Fast mode is one checkbox row in the menu, after Account. On is any tier past off;
  // a click turns it off, or on at the option's first tier.
  const quickFast: QuickMenuExtras["fast"] =
    fastMode && fastOffered
      ? {
          checked: fastModeIsOn(fastMode),
          onChange: (on) =>
            fastMode.onPick(on ? nextFastModeValue(fastMode, rememberedFastValue, fastMode.values) : fastMode.offValue),
        }
      : undefined;
  const quick: QuickMenuExtras = {
    ...(quickEffort ? { effort: quickEffort } : {}),
    ...(quickAccount ? { account: quickAccount } : {}),
    ...(quickFast ? { fast: quickFast } : {}),
  };
  // The button names the effort after the model ("Opus 5.5  Medium"), and its short name for a
  // narrow row ("Med"). Before the session reports, it names the held pick.
  const quickDetail = effortLabel ?? (awaiting ? (heldChoice?.name ?? pendingEffort) : undefined);
  const quickShort = effortLabel ? effortShort : awaiting ? heldShort : undefined;
  const usage = summary?.usage;
  const usageNote =
    showContextUsage && usage && usage.size > 0
      ? t(PICKER_LABELS.context, { percent: Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) })
      : undefined;

  const picksModel =
    snapshot.catalog.length > 0 || Boolean(harness) || Boolean(pickerCatalog?.harnesses.length && !harnessesListed);
  const chips = (
    <div className="acpmux-chips">
      {picksModel ? (
        <ModelPicker
          catalog={pickerEntries}
          harness={harness}
          model={shown}
          label={modelName ?? t(PICKER_LABELS.model)}
          sessionAuth={signIn?.sessionAuth}
          onSessionLogin={signIn?.loginSession}
          onSessionAuthRefresh={signIn?.recheckSession}
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
          {...(locked && fork ? { fork } : {})}
          {...(profiles ? { profiles } : {})}
          onCombo={combo}
          onHarnessHint={onHarnessHint}
          onHarnessEnable={onHarnessEnable}
          onAddAgent={onAddAgent}
          harnessFixed={locked}
          {...(signIn ? { signedOut: pickableSignedOut(signIn.signedOut, summary), onLogIn: signIn.logIn } : {})}
          {...(fastMode ? { fastMode: { ...fastMode, lastOnValue: fastMode.lastOnValue ?? rememberedFastValue } } : {})}
          catalogRefresh={catalogRefresh}
          harnessNotes={
            snapshot.switching?.phase === "failed"
              ? { [snapshot.switching.harness]: t("switch.failedShort") }
              : undefined
          }
          usage={usageNote}
          quick={quick}
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
      {/* With no harness installed (the Add harness chip above) there is nothing to set a mode for:
          the start mode, its highest-level fallback and the inert "Mode" placeholder are the chips'
          catalog fallback's, a harness acpmux does not have, so the row shows none of them. While
          acpmux has not listed its harnesses yet, `picksModel` holds and the placeholder keeps its
          place (#24517). */}
      {picksModel &&
        modes.length === 0 &&
        !hasGrants &&
        startMode &&
        startModeName &&
        pendingAccessModes.length === 0 && (
          <PendingMode
            label={startModeName}
            modeId={shownStart?.modeId}
            icon={pendingMenu?.rows.find((row) => row.id === shownStart?.modeId)?.icon}
          />
        )}
      {/* Granted folder trust and chat allowance stay revocable when the harness offers no modes. */}
      {(modes.length > 0 || hasGrants || pendingAccessModes.length > 0) && (
        <AccessMenu
          label={t(PICKER_LABELS.mode)}
          modes={modes.length > 0 ? modes : pendingAccessModes}
          current={mode?.id ?? (pendingAccessModes.length > 0 ? shownStart?.modeId : undefined)}
          sessionId={summary?.sessionId}
          warning={t(PICKER_LABELS.fullAccessWarning)}
          managed={fullAccessManaged}
          managedReason={t(PICKER_LABELS.fullAccessManaged)}
          help={t(PICKER_LABELS.modeHelp)}
          refusedReason={t(PICKER_LABELS.modeRefused)}
          permissionAccess={permissionAccess}
          onMode={onMode}
          {...(pendingMenu
            ? { heading: t(pendingMenu.heading ?? PICKER_LABELS.mode), numbered: pendingMenu.numbered }
            : {})}
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
      {/* A custom harness's other settings: each config option no chip above owns, picked like the
          effort level. Codex's collaboration mode stays on its command/mode paths. */}
      <AgentOptionsMenu
        options={extraOptions}
        managed={fullAccessManaged}
        managedReason={t(PICKER_LABELS.fullAccessManaged)}
        onPick={(configId, value) => onEffort(configId, value)}
      />
    </div>
  );
  return chips;
}

/// No start mode to name: the access chip holds its place as "Mode" (a borrowed answer's face).
const MODE_PLACEHOLDER: KeptStartMode = { modeId: "", borrowed: true };

/// The mode a chat will start in, before it reports its modes: the access chip's face (AccessMenu),
/// inert until the session's own replaces it in place. `modeId` is read from storage: only a
/// string names a mode that may skip approvals.
function PendingMode({ label, modeId, icon }: { label: string; modeId?: unknown; icon?: ModeIconName }) {
  const warning = typeof modeId === "string" && unrestricted(modeId) ? " acpmux-unrestricted" : "";
  return (
    <span className={`acpmux-mode acpmux-access acpmux-chip-pending${warning}`} aria-hidden="true">
      <span className="acpmux-picker-button acpmux-access-trigger">
        <ModeIcon modeId={modeId} icon={icon} />
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
  managed,
  managedReason,
  help,
  refusedReason,
  permissionAccess,
  onMode,
  heading,
  numbered = true,
}: {
  label: string;
  modes: ModeChoice[];
  current?: string;
  sessionId?: string;
  warning: string;
  /// Full access is managed off for this chat (`useFullAccessManaged`, this Mac's chats only).
  managed: boolean;
  managedReason: string;
  help: string;
  refusedReason: string;
  permissionAccess?: ComposerPermissionAccess;
  onMode(modeId: string): void | Promise<unknown>;
  /// The harness menu's mode supplies the icon layout even though its explanatory heading is not drawn.
  heading?: string;
  /// Rows show their number keys, as Claude Code's mode menu does (the keys pick either way).
  numbered?: boolean;
}) {
  const t = useT();
  // On New Tab the menu opens down, with no key hints (newTabComposer.ts).
  const newTab = useContext(OnNewTab);
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
  // MDM or a team policy keeps full access off (#23322, `managed`): its rows are disabled and say so.
  const blocked = (id: string) => refusedIds.includes(id) || (managed && unrestricted(id));
  // A chat that has not reported its mode (one acpmux has not started) names none, not the first,
  // and every mode, the first included, is a pick.
  const value = optimisticMode ?? current ?? "";
  const currentMode = modes.find((choice) => choice.id === value);
  const grants = permissionAccess?.grants ?? [];
  const pick = (next: string) => {
    if (blocked(next)) return;
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
  // A numbered menu (Claude Code's) draws no icon column, as Claude Code's mode menu does; the
  // button keeps the mode's symbol.
  const iconless = numbered && heading !== undefined;
  // Nothing left to pick (every other mode refused, no grants): a plain label, never a dead menu.
  if (
    refusedIds.length > 0 &&
    grants.length === 0 &&
    // A full-access row managed off, the current one included, keeps the menu: it stays, disabled
    // and saying why (reviews 37 and 48).
    modes.every(
      (choice) => !(managed && unrestricted(choice.id)) && (choice.id === value || refusedIds.includes(choice.id)),
    )
  ) {
    return (
      <span
        className={`acpmux-mode acpmux-access acpmux-access-fixed${unrestricted(value) ? " acpmux-unrestricted" : ""}`}
        data-fit-title={currentMode?.name ?? label}
        data-fit-title-unit="access"
        /* tooltip-allow: the chip is its shield alone; the tooltip says what it is and why it is fixed */
        title={`${tooltip}\n${refusedReason}`}
      >
        <ModeIcon modeId={value} icon={currentMode?.icon} />
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
          {modes.length > 0 ? <ModeIcon modeId={value} icon={currentMode?.icon} /> : <LockIcon />}
          <span className="acpmux-mode-text" data-fit-part="access" data-fit-forms="full">
            {currentMode?.name ?? (modes.length === 0 ? grants[0]?.label : undefined) ?? label}
          </span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup
          side={newTab ? "bottom" : "top"}
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
                  disabled={blocked(choice.id)}
                  shortcut={numbered && !newTab && index < 9 ? String(index + 1) : undefined}
                  className={`acpmux-access-item${unrestricted(choice.id) ? " acpmux-unrestricted" : ""}${iconless ? " acpmux-access-item-iconless" : ""}`}
                >
                  {!iconless && (
                    <span className="acpmux-access-item-icon" aria-hidden="true">
                      <ModeIcon modeId={choice.id} icon={choice.icon} />
                    </span>
                  )}
                  <span className="acpmux-menu-text">
                    {choice.recommended ? (
                      // The name and Claude Code's Recommended badge on one line.
                      <span className="acpmux-access-title">
                        <span className="acpmux-menu-label">{choice.name}</span>
                        <span className="acpmux-menu-badge">{t(RECOMMENDED_BADGE)}</span>
                      </span>
                    ) : (
                      <span className="acpmux-menu-label">{choice.name}</span>
                    )}
                    {managed && unrestricted(choice.id) ? (
                      // Managed off outranks an earlier refusal: the organization's bound is the reason now.
                      <span className="acpmux-menu-description">{managedReason}</span>
                    ) : refusedIds.includes(choice.id) ? (
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

/// What the keyboard tabs to, for leaving the context card forward.
const TABBABLE =
  'a[href],button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex]:not([tabindex="-1"])';

/// How much of the context window the session has used, as a neutral ring that fills. Resting the pointer
/// on it, or focusing it, shows the context card with no click (ContextCard.tsx; Leo 2026-10-21,
/// after Claude's and Codex's): the share and tokens used, the window as a stacked bar, and
/// Details ›, which opens the Inspector's Context section. A click pins the card until a press
/// outside; Escape closes it however it opened. Tab from the ring moves into the card's buttons,
/// and Tab past them goes on to what follows the ring. The ring itself never takes a hover pill
/// (contextCard.css).
export function ContextRing({
  used,
  size,
  setup,
  breakdown: reported,
  onCompact,
  onOpenDetails,
  working = false,
}: {
  used?: number;
  size?: number;
  /// Tokens the agent took before the conversation; the card splits it out when known.
  setup?: number;
  /// Claude Code's /context (`summary.contextBreakdown`): its categories replace the bar and parts.
  breakdown?: unknown;
  onCompact?(): void;
  /// Opens the Inspector at its Context section; the card shows Details › only with it.
  onOpenDetails?(): void;
  working?: boolean;
}) {
  const t = useT();
  const hover = useHoverCard(HOVER_INTENT.tooltipDelay);
  const [pinned, setPinned] = useState(false);
  const wrapper = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const card = useRef<HTMLDivElement>(null);
  const known = used !== undefined && size !== undefined && size > 0;
  const fraction = known ? Math.min(1, Math.max(0, used / size)) : 0;
  const percent = Math.round(fraction * 100);
  const label = known ? t(PICKER_LABELS.context, { percent }) : t("context.title");
  const breakdown = known ? contextBreakdown(reported) : undefined;
  const shown = known && (pinned || hover.open);
  const dismissHover = hover.dismiss;
  const closeCard = useCallback(() => {
    setPinned(false);
    dismissHover();
  }, [dismissHover]);
  // As Claude desktop's: a 14 px ring, a faint track with the share used drawn over it as an arc
  // from twelve o'clock (round ends), not a pie and not a spinner.
  const arcRadius = 6;
  const arcCircumference = 2 * Math.PI * arcRadius;
  useEffect(() => {
    // Keep the automation path truthful too: before the first usage report the ring is
    // intentionally inert, so opening it by label must not reveal an empty 0% card.
    const unregister = registerPicker(t("context.title"), () => {
      if (known) setPinned(true);
    });
    return unregister;
  }, [known, t]);
  useEffect(() => {
    // Usage can disappear when a session resets: no pinned card over a stale reading.
    if (!known) closeCard();
  }, [closeCard, known]);
  useEffect(() => {
    // Escape closes the card however it opened (hover, keyboard focus or a click), and takes the
    // press, so it doesn't also reach the composer.
    if (!shown) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      // Focus in the card goes back to the ring, before the card closes (the ring's focus would
      // open it again otherwise).
      if (card.current?.contains(document.activeElement)) trigger.current?.focus();
      closeCard();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [shown, closeCard]);
  useEffect(() => {
    // A pinned card goes on a press outside the ring and the card. The card is its outer element,
    // so a press on its padding is inside.
    if (!pinned) return;
    const onPress = (event: PointerEvent) => {
      const target = event.target as Node | null;
      if (target && (wrapper.current?.contains(target) || card.current?.contains(target))) return;
      closeCard();
    };
    document.addEventListener("pointerdown", onPress, true);
    return () => document.removeEventListener("pointerdown", onPress, true);
  }, [closeCard, pinned]);
  /// The card's buttons the keyboard reaches (Compact, Details ›).
  const cardButtons = () => [...(card.current?.querySelectorAll<HTMLElement>("button:not(:disabled)") ?? [])];
  /// Leaves the card forward: to whatever the page tabs to after the ring, and the card closes.
  const tabPastCard = () => {
    const ring = trigger.current;
    if (!ring) return;
    const order = [...ring.ownerDocument.querySelectorAll<HTMLElement>(TABBABLE)].filter(
      (element) => element.tabIndex >= 0 && !card.current?.contains(element),
    );
    const next = order[order.indexOf(ring) + 1];
    if (next) next.focus();
    else ring.blur();
    closeCard();
  };
  // Tab inside the open card: Shift-Tab off its first button goes back to the ring, Tab off its
  // last goes on past the ring. A document listener, as Escape's, since the card is a portal.
  const tabFromCard = useRef<(event: KeyboardEvent) => void>(() => {});
  tabFromCard.current = (event) => {
    if (event.key !== "Tab") return;
    const buttons = cardButtons();
    const at = buttons.indexOf(event.target as HTMLElement);
    if (at < 0) return;
    if (event.shiftKey && at === 0) {
      event.preventDefault();
      trigger.current?.focus();
    } else if (!event.shiftKey && at === buttons.length - 1) {
      event.preventDefault();
      tabPastCard();
    }
  };
  useEffect(() => {
    if (!shown) return;
    const onKey = (event: KeyboardEvent) => tabFromCard.current(event);
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [shown]);
  return (
    // tooltip-allow: before any usage the inert ring says why; once usage is known the card replaces it.
    <span
      ref={wrapper}
      className="acpmux-picker acpmux-context"
      title={known ? undefined : t("context.ringTooltipEmpty")}
    >
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-ring"
        data-menu={t("context.title")}
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={shown}
        // Before the first usage report there is nothing to show: the ring keeps its place, off.
        disabled={!known}
        {...hover.trigger}
        onClick={() => setPinned((was) => !was)}
        onKeyDown={(event) => {
          // Tab goes into the open card (it sits in a portal, out of the page's tab order).
          if (event.key !== "Tab" || event.shiftKey || !shown) return;
          const first = cardButtons()[0];
          if (!first) return;
          event.preventDefault();
          setPinned(true);
          first.focus();
        }}
      >
        <svg width={14} height={14} viewBox="0 0 14 14" aria-hidden="true" focusable="false">
          <circle
            cx="7"
            cy="7"
            r={arcRadius}
            fill="none"
            stroke="currentColor"
            strokeOpacity={0.3}
            strokeWidth={1.75}
          />
          {fraction > 0 && (
            <circle
              cx="7"
              cy="7"
              r={arcRadius}
              fill="none"
              stroke="currentColor"
              strokeWidth={1.75}
              strokeLinecap={fraction >= 1 ? "butt" : "round"}
              strokeDasharray={`${arcCircumference * fraction} ${arcCircumference}`}
              transform="rotate(-90 7 7)"
            />
          )}
        </svg>
      </button>
      <AnchoredCard
        anchor={shown ? trigger.current : null}
        // AnchoredCard makes it the shared glass hover card (ui-tooltip ui-card ui-glass).
        className={`acpmux-context-card acpmux-context-pop${breakdown ? " acpmux-context-pop--breakdown" : " acpmux-context-pop--compact"}`}
        side="top"
        interactive
        ariaLabel={t("context.title")}
        popupRef={card}
        hoverBridgeId={hover.card["data-cmux-hover-bridge"]}
        // On the card's outer element, so its padding counts as inside the card.
        onPointerEnter={hover.card.onPointerEnter}
        onPointerLeave={hover.card.onPointerLeave}
      >
        {known && (
          <div onFocusCapture={hover.card.onFocusCapture} onBlurCapture={hover.card.onBlurCapture}>
            <ContextCardBody
              used={used}
              size={size}
              setup={setup}
              breakdown={reported}
              working={working}
              onCompact={
                onCompact &&
                (() => {
                  closeCard();
                  onCompact();
                })
              }
              onOpenDetails={
                onOpenDetails &&
                (() => {
                  closeCard();
                  onOpenDetails();
                })
              }
            />
          </div>
        )}
      </AnchoredCard>
    </span>
  );
}

// The markers of cmux-tui/spec/full-access-modes.json, the rule acpmux and the app enforce.
const FULL_ACCESS_MARKERS = ["bypass", "fullaccess", "yolo", "dangerous", "autoapprove", "skippermissions"];

/// Modes that skip approvals (such as "Full access") draw in the theme's warning color: lowercased,
/// without `-`, `_` or spaces, the id contains a full-access marker.
export function unrestricted(modeId: string): boolean {
  const folded = modeId.toLowerCase().replace(/[-_ ]/g, "");
  return FULL_ACCESS_MARKERS.some((marker) => folded.includes(marker));
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
  tooltip,
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
  /// What the menu holds, as the trigger's tooltip: only a trigger that draws an icon and no text
  /// passes one (a picker showing its choice's name needs none).
  tooltip?: string;
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
    if (open && rows.length) scrollActiveMenuRow(menu.current, `${menuId}-${selected}`);
  }, [open, rows.length, menuId, selected]);

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
        // tooltip-allow: only an icon-only trigger (the composer's +) passes a tooltip.
        title={tooltip}
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
        <div
          ref={attach}
          style={menuStyle}
          className={`ui-popup ui-glass acpmux-menu acpmux-menu-${align}`}
          data-side="above"
        >
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
function Icon({
  children,
  size = 18,
  shield,
  modeIcon,
}: {
  children: React.ReactNode;
  size?: number;
  shield?: string;
  modeIcon?: ModeIconName;
}) {
  return (
    <svg
      className="acpmux-icon"
      data-shield={shield}
      data-mode-icon={modeIcon}
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
export const ShieldIcon = ({ shield, modeIcon }: { shield?: string; modeIcon?: ModeIconName }) => (
  <Icon shield={shield} modeIcon={modeIcon}>
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
/** Codex's approval icons (its own menu's): a raised hand for Ask for approval, a terminal prompt in
 * a shield for Approve for me, the shield with "!" for Full access. */
const HandIcon = () => (
  <Icon modeIcon="hand">
    <path d="M5.5 8.6V4.4a.9.9 0 0 1 1.8 0V8M7.3 7.6V3.3a.9.9 0 0 1 1.8 0v4.3M9.1 7.7V4a.9.9 0 0 1 1.8 0v4.6" />
    <path d="M10.9 7.4a.9.9 0 0 1 1.8 0v1.9a4.6 4.6 0 0 1-4.6 4.6h-.3a4 4 0 0 1-3-1.4L3.3 10.8a.9.9 0 0 1 1.3-1.2l.9.9" />
  </Icon>
);
const TerminalShieldIcon = () => (
  <Icon modeIcon="terminal-shield">
    <path d={SHIELD} />
    <path d="m5.8 6.4 1.6 1.4-1.6 1.4M8.4 9.6h2" />
  </Icon>
);
/** A mode's symbol: the harness's own icon for it when its menu draws one, else the shield family. */
function ModeIcon({ modeId, icon }: { modeId?: unknown; icon?: ModeIconName }) {
  if (icon === "hand") return <HandIcon />;
  if (icon === "terminal-shield") return <TerminalShieldIcon />;
  if (icon === "shield-alert") return <ShieldIcon shield="alert" modeIcon="shield-alert" />;
  return <ModeShield modeId={modeId} />;
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
/** Send's arrow: a plain outline glyph with the mic's stroke (Leo 2026-10-21: no disc). */
export const ArrowUpIcon = () => (
  <Icon>
    <path d="M8 12.9V3.4M3.9 7.5 8 3.4l4.1 4.1" />
  </Icon>
);
/** Steer's return glyph (↵): a prompt typed during a turn goes in now, as Codex and Claude draw it. */
export const ReturnIcon = () => (
  <Icon>
    <path d="M12.6 3.6v4.1a1.8 1.8 0 0 1-1.8 1.8H3.6M6.6 6.4 3.4 9.5l3.2 3.1" />
  </Icon>
);
/** Stop: a plain outline square with the mic's stroke, Claude Code desktop's, never a disc. */
export const StopIcon = () => (
  <Icon>
    <rect x="3.5" y="3.5" width="9" height="9" rx="1.5" />
  </Icon>
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

/// The name of the level `value` when the running model's row does not list it: the pane's own name
/// for a level it knows, else the agent's. None for no value, the agent's default or Ultracode.
function levelName(
  options: readonly { value: string; name?: string | null }[],
  value: string | undefined,
  t: (key: StringKey) => string,
): string | undefined {
  if (!value || isDefaultChoice({ id: value }) || value === "ultracode" || value === "ultrathink") return undefined;
  const key = LEVEL_KEYS[value];
  return key ? t(key) : options.find((option) => option.value === value)?.name || undefined;
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

/// The plain levels a catalog row can list (`PickerModel.efforts`).
const PLAIN_LEVELS = new Set(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]);

/// The Reasoning section's rows: the agent's levels, named by the pane, narrowed to what the
/// running model supports when its catalog row says. The agent-owned default sentinel is omitted,
/// and so are an older acpmux's Ultracode (now its own switch) and Ultrathink (a prompt keyword,
/// not a level).
export function reasoningChoices(
  options: { value: string; name?: string; description?: string }[],
  model: { efforts?: readonly string[]; defaultEffort?: string; own?: { efforts?: true }; noEffort?: true } | undefined,
  t: (key: StringKey) => string,
): Choice[] {
  if (model?.noEffort || (model?.own?.efforts && (model.efforts ?? []).length === 0)) return [];
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
