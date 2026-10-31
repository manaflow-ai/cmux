import { authText, canSessionLogin } from "./sessionAuth";
import React, { useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ChatAccountList } from "./chatAccounts";
import { isModelRouterKind } from "./routerKinds";
import { reasoningChoices, type Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { useOpenSide } from "../../ui/openSide";
import {
  useNativePopup,
  type NativePopupDescription,
  type NativePopupEvent,
  type NativePopupRow,
  shortcutRowId,
} from "../../ui/nativePopup";
import { OnNewTab } from "./newTabComposer";
import { QuickModelMenuFallback } from "./QuickModelMenuFallback";

import { usePopupHost } from "../../ui/UiProvider";
import { searchGroups, twinRows, type QuickMenu, type QuickModel } from "./QuickModelMenuFallback";
export { searchGroups, twinRows } from "./QuickModelMenuFallback";
export type {
  EffortLook,
  QuickMenu,
  QuickMenuExtras,
  QuickModel,
  QuickFamily,
  QuickFamilies,
  QuickSearchField,
  QuickProviderLook,
  QuickSearchGroups,
  QuickSearchGroup,
} from "./QuickModelMenuFallback";

const FILTER_ROWS = 9;
const rowValue = (model: Pick<QuickModel, "family" | "id">) => JSON.stringify([model.family, model.id]);
const runsOffers = (model: Pick<QuickModel, "id" | "offers">, current: string | undefined) =>
  !!model.offers?.some((offer) => offer.id === current);
type QuickProps = React.ComponentProps<typeof QuickModelMenuFallback>;

/** The browser gallery mounts its explicit fallback; an app host mounts only native descriptors. */
export function QuickModelMenu(props: QuickProps) {
  const native = usePopupHost()?.native;
  return native ? <NativeQuickModelMenu {...props} /> : <QuickModelMenuFallback {...props} />;
}

/// The compact model menu keeps numbered rows, Effort and Account flyouts, and Fast mode.
/// Its search field filters models in place using the full picker's matching.
function NativeQuickModelMenu(props: QuickProps) {
  const { open, onOpenChange, trigger, chip, menu, onMore, children } = props;
  const t = useT();
  const newTab = useContext(OnNewTab);
  const { open: sideOpen, setOpen: setSideOpen, side } = useOpenSide(trigger, newTab ? "bottom" : "top", 320);
  if (sideOpen !== open) setSideOpen(open);
  const { models, current, effort, auth, fast, ownModel } = menu;
  // The Chief picks its own model: no account, More models or refresh (as the web menu).
  const account = ownModel ? undefined : menu.account;
  const families = menu.families;
  const currentFamily = families?.list.find((family) => family.id === families.current);
  const currentModels = currentFamily ? [...currentFamily.models, ...currentFamily.more] : models;
  const currentModel = currentModels
    .flatMap((model) => [model, ...(model.offers ?? [])])
    .find((model) => model.id === current);
  // Explicitly unsupported effort overrides session options, as in the web menu.
  const levels =
    currentModel?.efforts?.length === 0 ? [] : (effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? []);
  const level = levels.find((choice) => choice.id === effort?.current);
  const accounts = useAccountList(open, account);
  const [tab, setTab] = useState(families?.current);
  const [query, setQuery] = useState("");
  const [moreFor, setMoreFor] = useState<string | undefined>();
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTab(families?.current ?? families?.list.find((family) => !family.starred)?.id);
      setQuery("");
      setMoreFor(undefined);
    }
  }
  const search = menu.search;
  const shown = families?.list.find((family) => family.id === tab);
  const onChatTab = !families || tab === families.current;
  const forkTab = !query && shown?.fork ? shown : undefined;
  const inlineMore = newTab && families !== undefined;
  const moreShown = inlineMore && !query && moreFor !== undefined && moreFor === tab;
  // The native menu keeps its field whenever it can search: typing on a hidden field has no
  // native path into the search. The `typed` and `long` looks are the web menu's (the gallery).
  const showField = !!search;
  const found = useMemo(() => (query && search ? search.find(query) : undefined), [query, search]);
  const groupLook = menu.searchGroups ?? "harness";
  const groups = useMemo(
    () => (found && families && groupLook === "harness" ? searchGroups(found, families.list) : undefined),
    [found, families, groupLook],
  );
  const rows: QuickModel[] = groups
    ? groups.flatMap((group) => group.rows)
    : (found ?? (!families ? models.map((model) => ({ ...model, family: "" })) : (shown?.models ?? [])));
  const railTabs = useMemo(() => {
    if (!families || !groups?.length) return families?.list ?? [];
    const matched = new Set(groups.map((group) => group.id));
    return families.list.filter((family) => matched.has(family.id));
  }, [families, groups]);
  const twins = useMemo(() => twinRows(groups ?? (found ? [{ id: "", name: "", rows: found }] : [])), [groups, found]);
  const providerLook = menu.providers ?? "row";
  const currentValue = families ? rowValue({ family: families.current ?? "", id: current ?? "" }) : (current ?? "");
  const valueOf = (model: Pick<QuickModel, "family" | "id">) => (families ? rowValue(model) : model.id);
  const runningRow = onChatTab
    ? (families ? shown?.models : models)?.find((model) => runsOffers(model, current))
    : undefined;
  const runningProvider = runningRow?.offers?.find((offer) => offer.id === current)?.provider;
  // Identifiers are short, stable across updates, and distinct even when a provider offer also
  // appears in the primary list. The native host requires uniqueness across the entire tree.
  const ids = useRef(new Map<string, string>());
  const idFor = (key: string) => {
    let id = ids.current.get(key);
    if (!id) {
      id = `row-${ids.current.size}`;
      ids.current.set(key, id);
    }
    return id;
  };
  const actions = new Map<string, (event: NativePopupEvent) => void>();
  const pickRow = (row: QuickModel) => {
    if (row.disabled) return;
    onOpenChange(false);
    const running = (!families || row.family === families.current) && row.id === current;
    if (running && !row.effort && !row.fast) return;
    if (query && search) search.pick(row);
    else if (!families && row.effort && menu.onModelEffort) menu.onModelEffort(row.id, row.effort);
    else if (!families) menu.onModel(row.id);
    else families.onPick(row);
  };
  const isRunning = (model: Pick<QuickModel, "family" | "id">) =>
    (!families || model.family === families.current) && model.id === current;
  /// A model's effort levels for its side dropdown (#27948), the same choices the web menu offers.
  const effortChoices = (model: QuickModel): Choice[] => {
    const running = isRunning(model);
    if (menu.inlineEffort !== true || (!families && !menu.onModelEffort)) return [];
    if (running && effort?.slider) return [];
    if (model.efforts?.length === 0) return [];
    const advertised = running
      ? levels
      : model.efforts !== undefined
        ? reasoningChoices(
            model.efforts.map((value) => ({ value })),
            { efforts: model.efforts },
            t,
          )
        : [];
    const ultracode = effort?.levels.find((choice) => choice.id === "ultracode");
    if (running && ultracode && !advertised.some((choice) => choice.id === "ultracode"))
      return [...advertised, ultracode];
    return advertised;
  };
  const pickEffort = (model: QuickModel, value: string) => {
    // The running model applies its effort through the reported option, as the Effort row does;
    // another model lands with its effort through the combo path.
    if (isRunning(model) && effort?.onPick) {
      onOpenChange(false);
      effort.onPick(value);
      if (model.fast) pickRow({ ...model, effort: undefined });
      return;
    }
    pickRow({ ...model, effort: value });
  };
  const action = (
    key: string,
    label: string,
    run: (event: NativePopupEvent) => void,
    extra: Partial<NativePopupRow> = {},
  ): NativePopupRow => {
    const id = idFor(key);
    if (!extra.disabled) actions.set(id, run);
    return { id, kind: "action", label, ...extra };
  };
  const closeThen = (run: () => void) => () => {
    onOpenChange(false);
    run();
  };
  const providerRows = (choice: QuickModel, scope: string): NativePopupRow[] =>
    (choice.offers ?? []).map((offer) =>
      action(`${scope}:offer:${rowValue(offer)}`, offer.provider, () => pickRow(offer), {
        checked: valueOf(offer) === currentValue,
        disabled: offer.disabled,
      }),
    );
  const modelRows = (choices: readonly QuickModel[], scope: string, numbered = false): NativePopupRow[] =>
    choices.flatMap((choice, index) => {
      const key = `${scope}:${rowValue(choice)}`;
      const detail = [
        groups ? undefined : choice.harness,
        choice.hint ?? choice.provider,
        choice.tag,
        twins.has(choice) ? choice.id : undefined,
      ]
        .filter(Boolean)
        .join(" · ");
      const row = action(key, choice.name, () => pickRow(choice), {
        checked: valueOf(choice) === currentValue,
        disabled: choice.disabled,
        ...(detail ? { description: detail } : {}),
        ...(!newTab && !query && numbered && index < FILTER_ROWS && valueOf(choice) !== currentValue
          ? { shortcut: String(index + 1) }
          : {}),
      });
      if (choice.offers?.length && providerLook === "submenu")
        return [{ ...row, kind: "submenu", children: providerRows(choice, key) }];
      if (choice.offers?.length && providerLook === "expanded")
        return [{ ...row, kind: "section" }, ...providerRows(choice, key)];
      // The model's effort is a side dropdown at the row's trailing edge (#27948): Return or a
      // click lands the model, its trailing item or Right opens its levels one per line.
      const levelsFor = effortChoices(choice);
      if (!levelsFor.length) return [row];
      const running = isRunning(choice);
      const now = running ? levelsFor.find((level) => level.id === effort?.current) : undefined;
      const look = menu.effortLook ?? "list";
      return [
        {
          ...row,
          value: now?.name ?? "",
          children: levelsFor.map((level) =>
            action(`${key}:effort:${level.id}`, level.name, () => pickEffort(choice, level.id), {
              checked: running && level.id === effort?.current,
              ...(look === "list" && level.recommended ? { value: t("picker.modeRecommended") } : {}),
            }),
          ),
        },
      ];
    });
  const visibleRows: NativePopupRow[] = groups
    ? groups.flatMap((group) => [
        { kind: "section" as const, id: idFor(`group:${group.id}`), label: group.name },
        ...modelRows(group.rows, `group:${group.id}`),
      ])
    : modelRows(rows, "models", true);
  if (!visibleRows.length)
    visibleRows.push({
      kind: "text",
      id: "empty",
      label: query
        ? t(families ? "picker.noMatchesFor" : "picker.noMatchesForQuery", { query })
        : (shown?.note ?? (ownModel ? t("picker.chiefOwnModel") : t("picker.noModels"))),
    });
  if (!query && shown?.note && shown.logIn)
    visibleRows.push(action("login", t("harness.logIn"), closeThen(shown.logIn)));
  if (forkTab)
    visibleRows.splice(
      0,
      visibleRows.length,
      action(
        "fork",
        t("picker.forkTo", { harness: forkTab.name }),
        closeThen(() => families?.onFork?.(forkTab.id)),
        { disabled: !families?.forkReady },
      ),
    );
  if (!query && !forkTab && inlineMore && shown?.more.length) {
    visibleRows.push(
      action("more-toggle", t("picker.moreModels"), () => setMoreFor(moreShown ? undefined : tab), {
        keepOpen: true,
      }),
    );
    if (moreShown) visibleRows.push(...modelRows(shown.more, "more"));
  }
  // The running row's own side dropdown replaces the standalone Effort row, as in the web menu.
  const runningHasEffort = rows.some(
    (row) => row.id === current && effortChoices(row).length > 0 && (!row.offers || providerLook === "row"),
  );
  if (!query && onChatTab && effort && levels.length > 1 && (effort.slider || !runningHasEffort)) {
    const selected = levels.findIndex((choice) => choice.id === effort.current);
    const recommended = levels.findIndex((choice) => choice.recommended);
    const children = effort.slider
      ? [
          action(
            "effort-slider",
            t("effort.title"),
            (event) => {
              const index = Number(event.value);
              if (event.value !== undefined && Number.isInteger(index) && levels[index])
                effort.onPick(levels[index].id);
            },
            {
              kind: "slider",
              value: String(selected >= 0 ? selected : Math.max(0, recommended)),
              minimum: 0,
              maximum: levels.length - 1,
              step: 1,
              keepOpen: true,
            },
          ),
        ]
      : levels.map((choice) =>
          action(
            `effort:${choice.id}`,
            choice.name,
            closeThen(() => effort.onPick(choice.id)),
            { checked: choice.id === effort.current },
          ),
        );
    visibleRows.push({
      kind: "submenu",
      id: "effort",
      label: t("effort.title"),
      value: level?.name,
      children,
    });
  }
  if (!query && runningRow?.offers?.length && providerLook === "row")
    visibleRows.push({
      kind: "submenu",
      id: "model-providers",
      label: t("picker.provider"),
      value: runningProvider,
      children: providerRows({ ...runningRow, family: families?.current ?? "" }, "running-provider"),
    });
  if (!query && !forkTab && !ownModel && !inlineMore && families && shown?.more.length)
    visibleRows.push({
      kind: "submenu",
      id: "more-models",
      label: t("picker.moreModels"),
      children: modelRows(shown.more, "more"),
    });
  if (!query && !families && !ownModel)
    visibleRows.push(
      action(
        "more-full",
        t("picker.moreModels"),
        closeThen(() => onMore()),
      ),
    );
  if (!query && onChatTab && account) {
    const list = accounts.list;
    const choices =
      list?.accounts.filter(
        (choice) =>
          choice.kind === "direct-subscription" ||
          choice.kind === "direct-api-key" ||
          isModelRouterKind(choice.kind) ||
          choice.id === list.active,
      ) ?? [];
    const accountRows: NativePopupRow[] = [];
    if (accounts.switchFailed)
      accountRows.push({
        kind: "text",
        id: "provider-refused",
        label: t("picker.accountSwitchFailed"),
      });
    if (!list)
      accountRows.push({
        kind: "text",
        id: "provider-status",
        label: accounts.failed ? t("picker.accountFailed") : "…",
      });
    else {
      const pickAccount = (id: string | null) =>
        closeThen(() => {
          if ((list.active ?? null) !== id) accounts.pick(id);
        });
      accountRows.push(
        action("provider-default", t("picker.harnessLogin"), pickAccount(null), {
          checked: !list.active,
          disabled: list.scope !== "chat" && !!list.active,
        }),
      );
      const direct = choices.filter((choice) => !isModelRouterKind(choice.kind));
      const routers = choices.filter((choice) => isModelRouterKind(choice.kind));
      const routes = (items: typeof choices) =>
        items.map((choice) =>
          action(`provider:${choice.id}`, choice.name, pickAccount(choice.id), {
            checked: choice.id === list.active,
          }),
        );
      // Every layout but inline lists Cmux routers under a Provider heading (#28020).
      if (menu.routeLayout !== "inline") {
        accountRows.push(...routes(direct));
        if (routers.length)
          accountRows.push({ kind: "section", id: "provider-group", label: t("picker.provider") }, ...routes(routers));
      } else accountRows.push(...routes(choices));
      if (!choices.length) accountRows.push({ kind: "text", id: "provider-hint", label: t("picker.accountHint") });
    }
    const accountValue = accounts.switchFailed
      ? t("picker.accountSwitchFailed")
      : list
        ? (list.accounts.find((choice) => choice.id === list.active)?.name ?? t("picker.harnessLogin"))
        : undefined;
    if (menu.routeLayout === "inline")
      visibleRows.push({ kind: "section", id: "providers", label: t("picker.account") }, ...accountRows);
    else
      // The composer's account switcher (#28020).
      visibleRows.push({
        kind: "submenu",
        id: "providers",
        label: t("picker.account"),
        value: accountValue,
        children: accountRows,
      });
  }
  const authLabel = auth && authText(auth.verdict, t);
  if (!query && authLabel) {
    visibleRows.push({ kind: "text", id: "auth-status", label: authLabel });
    if (canSessionLogin(auth.verdict) && auth.onLogin)
      visibleRows.push(action("auth-login", t("harness.logIn"), closeThen(auth.onLogin)));
    if (auth.onRefresh) visibleRows.push(action("auth-refresh", t("harnesses.checkAgain"), closeThen(auth.onRefresh)));
  }
  if (!query && onChatTab && fast)
    visibleRows.push(
      action(
        "fast",
        t("picker.fastMode"),
        (event) => fast.onChange(event.value === undefined ? !fast.checked : event.value === "true"),
        { kind: "toggle", checked: fast.checked, keepOpen: true },
      ),
    );
  const rail =
    families &&
    railTabs.map((family) =>
      action(
        `family:${family.id}`,
        family.name,
        () => {
          if (family.launch && !family.note) {
            onOpenChange(false);
            families.onLaunch?.(family.id);
          } else {
            setTab(family.id);
            setQuery("");
            setMoreFor(undefined);
          }
        },
        {
          ...(family.mark ? { icon: family.mark } : {}),
          checked: family.id === tab,
          keepOpen: true,
          disabled: family.launch && families.forkReady === false,
        },
      ),
    );
  // Add harness is the last item in the harness strip (#26503).
  if (rail && families?.onAddHarness)
    rail.push(
      action("add-harness", t("modelPicker.addHarness"), closeThen(families.onAddHarness), { icon: "action.add" }),
    );
  const model: NativePopupDescription = {
    side,
    align: "start",
    width: families ? 310 : 280,
    rows: visibleRows,
    ...(rail ? { rail, railWidth: 44 } : {}),
    ...(showField ? { search: { id: "query", value: query, placeholder: t("picker.search") } } : {}),
    ...(menu.update
      ? {
          footer: [
            action("update", t("harness.update"), closeThen(menu.update.run), {
              description: menu.update.text,
            }),
          ],
        }
      : {}),
  };
  const onEvent = (event: NativePopupEvent) => {
    if (event.type === "search" && event.id === "query") {
      // A digit typed into the empty field picks that numbered row, as in the web menu.
      const numbered = shortcutRowId(visibleRows, query, event.value);
      if (numbered) actions.get(numbered)?.({ ...event, type: "pick", id: numbered });
      else setQuery(event.value ?? "");
      return;
    }
    if (event.type === "pick" || event.type === "change") actions.get(event.id ?? "")?.(event);
  };
  const { available } = useNativePopup({
    open,
    model,
    anchor: () => trigger.current,
    onEvent,
    onDismiss: () => onOpenChange(false),
  });
  // The host could not show this opening (no window): the web menu draws it instead.
  if (!available) return <QuickModelMenuFallback {...props} />;
  return (
    <button
      type="button"
      ref={trigger}
      className="acpmux-picker-button"
      data-menu={chip["data-menu"]}
      aria-label={chip.label}
      title={chip.title}
      aria-haspopup="menu"
      aria-expanded={open}
      onClick={() => onOpenChange(!open)}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          onOpenChange(true);
        }
      }}
    >
      {children}
    </button>
  );
}

function useAccountList(open: boolean, account: QuickMenu["account"]) {
  const [list, setList] = useState<ChatAccountList>();
  const [failed, setFailed] = useState(false);
  const [switchFailed, setSwitchFailed] = useState(false);
  const sessionId = account?.sessionId;
  const accounts = account?.accounts;
  useEffect(() => {
    if (!open || !sessionId || !accounts) return;
    let live = true;
    setFailed(false);
    accounts.list(sessionId).then(
      (next) => live && setList(next),
      () => live && setFailed(true),
    );
    return () => {
      live = false;
    };
  }, [open, sessionId, accounts]);
  // The chat the latest pick was for: a late answer for another chat changes nothing here.
  const pickFor = useRef(sessionId);
  // Another chat's accounts never show for this one.
  useEffect(() => {
    pickFor.current = sessionId;
    setList(undefined);
    setSwitchFailed(false);
  }, [sessionId]);
  const pick = (routeId: string | null) => {
    if (!sessionId || !accounts) return;
    const forSession = sessionId;
    setList((old) =>
      old
        ? {
            ...old,
            ...(routeId ? { active: routeId, scope: "chat" } : { active: undefined, scope: undefined }),
          }
        : old,
    );
    accounts.set(sessionId, routeId).then(
      () => pickFor.current === forSession && setSwitchFailed(false),
      () => {
        if (pickFor.current !== forSession) return;
        setSwitchFailed(true);
        // The next open reads where the chat really is.
        setList(undefined);
      },
    );
  };
  return { list, failed, switchFailed, pick };
}
