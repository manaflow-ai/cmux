// Settings > Customize (Leo, 2026-11-22, ask-931361017e: "it should just be as easy as a click
// toggle"): every customization the page knows, one switch each, in one dense checklist. Groups:
// Experiments, Labs, the Customization Library's entries, the verified looks, and every other
// switch (collapsed, searchable). The rows come from the schema (customizeChecklist.ts); a setting
// writes through `store.set`, the ToggleEditor path, and is locked exactly where SettingRow locks it;
// a library entry or an installed look runs the library card's own `on`/`off`. A look that is not
// installed has no host op that installs it yet: its click opens the Customize chat with the
// install drafted (`store.askCmux`). Opened by `#/settings/customize`.
//
// Recovery (Leo, 2026-11-23, c-dc594b45e0: "I want people to not accidentally soft lock themselves
// and like have good recovery options"): Experiments, Labs and the library each get a Turn All Off
// in their head while any of their switches is on. A setting goes back to its shipped default
// (`store.reset`, the row menu's Reset to Default), so a switch that ships on stays on; a library
// entry runs `customize library off`. The app menu's Customizations submenu has the same row,
// native, for when this page is the thing that broke (CustomizationsMenu.swift).
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useMemo, useState } from "react";
import { Input } from "../../../ui/Input";
import { categoryById, homes } from "../categories";
import { useSettingsState, useStore } from "../context";
import {
  checklistGroups,
  filterGroups,
  setupEntryName,
  toggleRowsByGroup,
  type ChecklistGroup,
  type ChecklistGroupId,
  type ChecklistItem,
} from "../customizeChecklist";
import { shippedLooks } from "../customizeLooks";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import type { LibraryRun } from "../ops";
import { rowsByKey, schema } from "../schema";
import { LIBRARY_KEY, libraryQuery, type LibraryRead } from "../sectionQueries";
import { managedOf, managedText, valueOf } from "../store";
import { t } from "../strings";

/** How the checklist draws (gallery `settings.customize-checklist`). `rows`, the shipped one, is a
 * dense list: switch, title, one help line. `chips` is a wrap of pill toggles (title only); `menu`
 * is a menu-like list with a check mark and no help line. */
export type ChecklistLayout = "rows" | "chips" | "menu";

const GROUP_TITLE: Record<ChecklistGroupId, string> = {
  experiments: "settingsPage.customizeChecklist.experiments",
  labs: "settingsPage.customizeChecklist.labs",
  library: "settingsPage.customizeChecklist.library",
  looks: "settingsPage.customizeChecklist.looks",
  all: "settingsPage.customizeChecklist.all",
};

export function CustomizeChecklistCard() {
  const store = useStore();
  const state = useSettingsState();
  const queryClient = useQueryClient();
  const library = useQuery(libraryQuery(store));
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const devBuild = state.host?.dev_build === true;
  const rows = useMemo(
    () =>
      toggleRowsByGroup(schema.rows, (row) => {
        const home = homes.get(row.key);
        return home !== undefined && (devBuild || !categoryById(home.category).devOnly);
      }),
    [devBuild],
  );
  const groups = checklistGroups({
    rows,
    value: (key) => valueOf(state, key),
    locked: (key) => {
      const managed = managedOf(state, key);
      if (managed) return managedText(managed);
      if (!state.connected || !state.readable) return t("settingsPage.customizeChecklist.connecting");
      return null;
    },
    library: library.data?.library ?? null,
    libraryLocked: busy ? t("settingsPage.customizeChecklist.busy") : null,
    looks: shippedLooks(),
  });
  // The library card's run: drop a list read on its way before and after the change, so an older
  // listing never draws over it (CustomizeLibraryCard `run`).
  const runLibrary = (change: LibraryRun) => {
    setBusy(true);
    setRefusal(null);
    return queryClient
      .cancelQueries({ queryKey: LIBRARY_KEY })
      .then(() => store.customizeLibrary(change))
      .then(async (answer) => {
        await queryClient.cancelQueries({ queryKey: LIBRARY_KEY });
        if (answer.library)
          queryClient.setQueryData<LibraryRead>(LIBRARY_KEY, { library: answer.library, refusal: null });
        setRefusal(answer.refusal);
      })
      .finally(() => setBusy(false));
  };
  const looks = shippedLooks();
  const onToggle = (item: ChecklistItem, on: boolean) => {
    if (item.group === "library") return void runLibrary({ verb: on ? "on" : "off", name: item.id.slice(8) });
    if (item.group === "looks") {
      const look = looks.find((each) => `look:${each.id}` === item.id);
      if (!look) return;
      if (item.installs)
        return void store.askCmux(t("settingsPage.customizeChecklist.installDraft", look.name, look.reference));
      return void runLibrary({ verb: on ? "on" : "off", name: setupEntryName(look.id) });
    }
    void store.set(item.id, on);
  };
  const onTurnAllOff = async (group: ChecklistGroup) => {
    const on = turnOffTargets(group);
    if (group.id === "library") {
      for (const item of on) await runLibrary({ verb: "off", name: item.id.slice(8) });
      return;
    }
    for (const item of on) await store.reset(item.id);
  };
  return (
    <CustomizeChecklistView
      groups={groups}
      query={query}
      onQuery={setQuery}
      onToggle={onToggle}
      onTurnAllOff={(group) => void onTurnAllOff(group)}
      refusal={refusal}
    />
  );
}

/** The groups with a Turn All Off: the ones that hold opt-in switches. */
const TURN_OFF_GROUPS: ReadonlySet<ChecklistGroupId> = new Set(["experiments", "labs", "library"]);

/** What Turn All Off changes in `group`: each switch that is on, not locked, and (for a setting) off
 * by default, so the reset leaves nothing on that the person did not turn on. */
export function turnOffTargets(group: ChecklistGroup): ChecklistItem[] {
  if (!TURN_OFF_GROUPS.has(group.id)) return [];
  return group.items.filter(
    (item) => item.on && item.locked === null && (group.id === "library" || rowsByKey.get(item.id)?.default !== true),
  );
}

export function CustomizeChecklistView({
  groups,
  query,
  onQuery,
  onToggle,
  onTurnAllOff,
  refusal = null,
  layout = "rows",
  allOpen: allOpenAtFirst = false,
}: {
  groups: readonly ChecklistGroup[];
  query: string;
  onQuery: (query: string) => void;
  onToggle: (item: ChecklistItem, on: boolean) => void;
  /** Turns every opt-in switch of the group off (``turnOffTargets``); no button when absent. */
  onTurnAllOff?: (group: ChecklistGroup) => void;
  refusal?: string | null;
  layout?: ChecklistLayout;
  allOpen?: boolean;
}) {
  const searchId = useId();
  const [allOpen, setAllOpen] = useState(allOpenAtFirst);
  const shown = filterGroups(groups, query);
  const searching = query.trim() !== "";
  return (
    <section className="group" data-card="customizeChecklist" data-checklist-layout={layout} id="customize-checklist">
      <h3 className="group-title">{t("settingsPage.customizeChecklist.title")}</h3>
      <label className="search checklist-search" htmlFor={searchId}>
        <Icon name="search" />
        <Input
          id={searchId}
          className="field search-input"
          type="search"
          value={query}
          placeholder={t("settingsPage.customizeChecklist.search")}
          aria-label={t("settingsPage.customizeChecklist.search")}
          spellCheck={false}
          onChange={(event) => onQuery(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape" && query) {
              event.preventDefault();
              onQuery("");
            }
          }}
        />
      </label>
      {refusal && (
        <div className="row-help checklist-refusal" role="alert">
          {refusal}
        </div>
      )}
      {searching && shown.length === 0 && (
        <div className="row-help checklist-empty">{t("settingsPage.customizeChecklist.noMatch", query.trim())}</div>
      )}
      {shown.map((group) => {
        const collapsible = group.id === "all" && !searching;
        const open = !collapsible || allOpen;
        return (
          <div className="checklist-group" data-checklist-group={group.id} key={group.id}>
            <div className="checklist-head">
              {collapsible ? (
                <button
                  type="button"
                  className="checklist-toggle-all"
                  aria-expanded={open}
                  onClick={() => setAllOpen(!open)}
                >
                  <Icon name="chevron" />
                  <span className="checklist-group-title">{t(GROUP_TITLE[group.id])}</span>
                </button>
              ) : (
                <span className="checklist-group-title">{t(GROUP_TITLE[group.id])}</span>
              )}
              <span className="checklist-head-trailing">
                {onTurnAllOff && turnOffTargets(group).length > 0 && (
                  <button
                    type="button"
                    className="link-button checklist-turn-off"
                    data-checklist-turn-off={group.id}
                    onClick={() => onTurnAllOff(group)}
                  >
                    {t("settingsPage.customizeChecklist.turnAllOff")}
                  </button>
                )}
                <span className="checklist-count" data-checklist-count="">
                  {t("settingsPage.customizeChecklist.count", String(group.on), String(group.total))}
                </span>
              </span>
            </div>
            {open &&
              (group.items.length === 0 ? (
                <div className="row-help checklist-empty">{t("settingsPage.customizeChecklist.none")}</div>
              ) : (
                <div className={layout === "chips" ? "checklist-chips" : "checklist-items"}>
                  {group.items.map((item) => (
                    <ChecklistRow key={item.id} item={item} layout={layout} onToggle={onToggle} />
                  ))}
                </div>
              ))}
          </div>
        );
      })}
    </section>
  );
}

function ChecklistRow({
  item,
  layout,
  onToggle,
}: {
  item: ChecklistItem;
  layout: ChecklistLayout;
  onToggle: (item: ChecklistItem, on: boolean) => void;
}) {
  const labelId = useId();
  const locked = item.locked !== null;
  const help = item.locked ?? (item.help || (item.installs ? t("settingsPage.customizeChecklist.installHint") : ""));
  const hover = item.detail && item.detail !== help ? item.detail : undefined;
  if (layout === "chips" || layout === "menu") {
    return (
      <button
        type="button"
        className={layout === "chips" ? "checklist-chip" : "checklist-menu-item"}
        data-checklist-item={item.id}
        aria-pressed={item.on}
        disabled={locked}
        // tooltip-allow: a chip shows only its title; the lock reason or the detail shows nowhere else
        title={item.locked ?? (item.detail || help || undefined)}
        onClick={() => onToggle(item, !item.on)}
      >
        <span className="checklist-mark-icon" aria-hidden="true">
          {item.on ? <Icon name="check" /> : item.installs ? <Icon name="plus" /> : null}
        </span>
        <span className="row-title">{item.title}</span>
        {locked && <Icon name="lock" />}
      </button>
    );
  }
  return (
    <div className="checklist-row" data-checklist-item={item.id} data-locked={locked ? "" : undefined}>
      {/* tooltip-allow: the detail, when it differs from the help line, shows nowhere else */}
      <div className="checklist-text" title={hover}>
        <span className="row-title" id={labelId}>
          {item.title}
          {locked && <Icon name="lock" />}
        </span>
        {help && <span className="row-help checklist-help">{help}</span>}
      </div>
      {item.installs ? (
        <button
          type="button"
          className="checklist-install"
          aria-labelledby={labelId}
          onClick={() => onToggle(item, true)}
        >
          {t("settingsPage.customizeChecklist.install")}
        </button>
      ) : (
        <Switch checked={item.on} disabled={locked} labelId={labelId} onToggle={(next) => onToggle(item, next)} />
      )}
    </div>
  );
}
