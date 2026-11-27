// Settings > Customize (Leo, 2026-11-22, ask-931361017e: "it should just be as easy as a click
// toggle"): every customization the page knows, one switch each, in one dense checklist. Groups:
// Experiments, Labs, the Customization Library's entries, the verified looks, and every other
// switch (collapsed, searchable). The rows come from the schema (customizeChecklist.ts); a setting
// writes through `store.set`, the ToggleEditor path, and is locked exactly where SettingRow locks it;
// a library entry or an installed look runs the library card's own `on`/`off`. A look that is not
// installed has no host op that installs it yet: its click opens the Customize chat with the
// install drafted (`store.askCmux`). A sidebar look (`sidebar.look`'s choices) is one switch each:
// on picks it, off resets the key to the default look. Opened by `#/settings/customize`.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useMemo, useState } from "react";
import { Input } from "../../../ui/Input";
import { categoryById, homes } from "../categories";
import { useSettingsState, useStore } from "../context";
import {
  checklistGroups,
  filterGroups,
  setupEntryName,
  SIDEBAR_LOOK_KEY,
  sidebarLookOf,
  toggleRowsByGroup,
  type ChecklistGroup,
  type ChecklistGroupId,
  type ChecklistItem,
} from "../customizeChecklist";
import { shippedLooks } from "../customizeLooks";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import type { LibraryRun } from "../ops";
import { schema } from "../schema";
import type { Standup } from "../ops";
import { LIBRARY_KEY, libraryQuery, STANDUP_KEY, standupQuery, type LibraryRead } from "../sectionQueries";
import { Button } from "../../../ui/Button";
import { managedOf, managedText, valueOf } from "../store";
import { t } from "../strings";
import { copyTextResult } from "../../../agent-session/acpmux/conversation/clipboard";

/** How the checklist draws (gallery `settings.customize-checklist`). `rows`, the shipped one, is a
 * dense list: switch, title, one help line. `chips` is a wrap of pill toggles (title only); `menu`
 * is a menu-like list with a check mark and no help line. */
export type ChecklistLayout = "rows" | "chips" | "menu";

const GROUP_TITLE: Record<ChecklistGroupId, string> = {
  code: "settingsPage.customizeChecklist.code",
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
  const standup = useQuery(standupQuery(store));
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const devBuild = state.host?.dev_build === true;
  const rows = useMemo(() => {
    const shown = (row: (typeof schema.rows)[number]) => {
      const home = homes.get(row.key);
      return home !== undefined && (devBuild || !categoryById(home.category).devOnly);
    };
    const look = schema.rows.find((row) => row.key === SIDEBAR_LOOK_KEY);
    return { ...toggleRowsByGroup(schema.rows, shown), sidebarLook: look && shown(look) ? look : null };
  }, [devBuild]);
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
    sidebarLook: rows.sidebarLook,
    standup: standup.data ?? null,
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
        // The standup lines say on or off: read them again after every change.
        void queryClient.invalidateQueries({ queryKey: STANDUP_KEY });
      })
      .finally(() => setBusy(false));
  };
  const looks = shippedLooks();
  const onToggle = (item: ChecklistItem, on: boolean) => {
    const sidebarLook = sidebarLookOf(item);
    if (sidebarLook !== null)
      return void (on ? store.set(SIDEBAR_LOOK_KEY, sidebarLook) : store.reset(SIDEBAR_LOOK_KEY));
    if (item.group === "library" || item.group === "code")
      return void runLibrary({ verb: on ? "on" : "off", name: item.id.slice(8) });
    if (item.group === "looks") {
      const look = looks.find((each) => `look:${each.id}` === item.id);
      if (!look) return;
      if (item.installs)
        return void store.askCmux(t("settingsPage.customizeChecklist.installDraft", look.name, look.reference));
      return void runLibrary({ verb: on ? "on" : "off", name: setupEntryName(look.id) });
    }
    void store.set(item.id, on);
  };
  return (
    <CustomizeChecklistView
      groups={groups}
      query={query}
      onQuery={setQuery}
      onToggle={onToggle}
      refusal={refusal}
      standup={standup.data ?? null}
    />
  );
}

export function CustomizeChecklistView({
  groups,
  query,
  onQuery,
  onToggle,
  refusal = null,
  layout = "rows",
  allOpen: allOpenAtFirst = false,
  standup = null,
  standupOpen: standupOpenAtFirst = false,
}: {
  groups: readonly ChecklistGroup[];
  query: string;
  onQuery: (query: string) => void;
  onToggle: (item: ChecklistItem, on: boolean) => void;
  refusal?: string | null;
  layout?: ChecklistLayout;
  allOpen?: boolean;
  /** `cmux customize library standup`; null (an older host) hides the Standup button. */
  standup?: Standup | null;
  standupOpen?: boolean;
}) {
  const searchId = useId();
  const [allOpen, setAllOpen] = useState(allOpenAtFirst);
  const [standupOpen, setStandupOpen] = useState(standupOpenAtFirst);
  const shown = filterGroups(groups, query);
  const searching = query.trim() !== "";
  return (
    <section className="group" data-card="customizeChecklist" data-checklist-layout={layout} id="customize-checklist">
      <div className="checklist-title-row">
        <h3 className="group-title">{t("settingsPage.customizeChecklist.title")}</h3>
        {standup && standup.lines.length > 0 && (
          <Button
            variant="ghost"
            size="sm"
            className="button"
            aria-expanded={standupOpen}
            data-checklist-action="standup"
            onClick={() => setStandupOpen(!standupOpen)}
          >
            {t("settingsPage.customizeChecklist.standup")}
          </Button>
        )}
      </div>
      {standupOpen && standup && <StandupPanel standup={standup} />}
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
              <span className="checklist-count" data-checklist-count="">
                {t("settingsPage.customizeChecklist.count", String(group.on), String(group.total))}
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

/** Leo, 2026-11-23: "a list of prs or repos whatever that i can just present with standup". The
 * CLI's lines as they read out loud, each with its link, and Copy for the whole Markdown. */
export function StandupPanel({ standup }: { standup: Standup }) {
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);
  return (
    <div className="checklist-standup" data-checklist-standup="">
      <div className="checklist-head">
        <span className="checklist-group-title">{t("settingsPage.customizeChecklist.standup")}</span>
        <span className="checklist-count">
          {t("settingsPage.customizeChecklist.count", String(standup.on), String(standup.lines.length))}
        </span>
        <Button
          variant="ghost"
          size="sm"
          className="button"
          data-checklist-action="copyStandup"
          onClick={() => {
            setCopyFailed(false);
            void copyTextResult(standup.text).then((ok) => {
              setCopied(ok);
              setCopyFailed(!ok);
            });
          }}
        >
          {t(
            copyFailed
              ? "inspector.copyFailed"
              : copied
                ? "settingsPage.customizeChecklist.copied"
                : "settingsPage.customizeChecklist.copy",
          )}
        </Button>
      </div>
      <ul className="checklist-standup-lines selectable">
        {standup.lines.map((line) => (
          <li key={line.name} data-standup-line={line.name} data-on={line.on ? "" : undefined}>
            <span className="checklist-mark-icon" aria-hidden="true">
              {line.on ? <Icon name="check" /> : null}
            </span>
            <span className="row-title">
              {line.link ? (
                <a href={line.link} target="_blank" rel="noreferrer">
                  {line.title}
                </a>
              ) : (
                line.title
              )}
            </span>
            <span className="row-help"> {line.status}</span>
          </li>
        ))}
      </ul>
    </div>
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
