// Settings > Skills (Leo 2026-11-08): every skill Claude Code and Codex load on this Mac, by harness and
// by where it comes from (Personal, each Project, each Plugin, Admin, System), as this Mac's daemon
// lists them (`cmux.settings.skills.list`, the daemon's `skills-list`). A row turns its skill (or its
// whole plugin) on or off, opens its SKILL.md in cmux's editor, shows it in Finder, and unfolds its file
// and full description. Search and the harness filter narrow the list through a lowercased index built
// once per read, so a keystroke scans strings and redraws only the rows that change. New Skill makes a
// skill in Personal or a listed project and opens its file. The list is read with the section
// (sectionQueries) and after each gesture; it does not poll.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { memo, useCallback, useDeferredValue, useId, useMemo, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Switch } from "../../../ui/Switch";
import { Tooltip } from "../../../ui/Tooltip";
import { useStore } from "../context";
import { Icon } from "../icons";
import type { Skill, SkillHarness, SkillsRun, SkillsRunResult, SkillsState } from "../ops";
import { SKILLS_KEY, skillsQuery } from "../sectionQueries";
import {
  HARNESSES,
  filterSkills,
  groupSkills,
  harnessTitle,
  modeTitle,
  pluginName,
  projectName,
  scopeTitle,
  shortPath,
  skillIndex,
  skillsErrorText,
  validSkillName,
  type HarnessFilter,
  type SkillGroup,
} from "../skills";
import { t } from "../strings";
import { Select } from "../editors/Select";

/** How the list draws (gallery `settings.skills-layouts`). `list`, the shipped one: one dense row per
 * skill under a header per harness and source. `tiles`: two columns of tiles. `split`: the names on
 * the left, the selected skill's file, description and actions on the right. */
export type SkillsLayout = "list" | "tiles" | "split";

/** The card: the daemon's list and each gesture, refreshed after it. */
export function SkillsCard() {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(skillsQuery(store));
  // Stable across reads, so the rows' actions stay the same object and a read redraws only changed rows.
  const run = useCallback(
    async (gesture: SkillsRun): Promise<SkillsRunResult> => {
      if (gesture.action === "set_enabled") {
        // The switch moves at once (every row its gesture turns: a plugin's turns all of its skills);
        // the read after the reply settles it, and a refusal puts it back.
        const now = queryClient.getQueryData<SkillsState | null>(SKILLS_KEY);
        const target = now?.skills?.find((skill) => skill.id === gesture.id);
        queryClient.setQueryData<SkillsState | null>(SKILLS_KEY, (state) =>
          state && target
            ? { ...state, skills: state.skills?.map((skill) => turned(skill, target, gesture.enabled)) }
            : state,
        );
      }
      const reply = await store.runSkills(gesture);
      if (gesture.action !== "open" && gesture.action !== "reveal")
        await queryClient.invalidateQueries({ queryKey: SKILLS_KEY });
      return reply;
    },
    [store, queryClient],
  );
  return <SkillsPanel state={query.data ?? null} loading={!query.isFetched} onRun={run} />;
}

/** `skill` after `target` is turned `enabled`: the same skill, or every skill of the same plugin. */
function turned(skill: Skill, target: Skill, enabled: boolean): Skill {
  const same =
    skill.id === target.id ||
    (target.toggle === "plugin" &&
      skill.toggle === "plugin" &&
      skill.harness === target.harness &&
      skill.plugin === target.plugin);
  return same ? { ...skill, enabled } : skill;
}

/** The card's body over a state (the card's read, or a gallery fixture). */
export function SkillsPanel({
  state,
  loading,
  onRun,
  layout = "list",
}: {
  state: SkillsState | null;
  loading: boolean;
  onRun: (run: SkillsRun) => Promise<SkillsRunResult>;
  layout?: SkillsLayout;
}) {
  const [query, setQuery] = useState("");
  const [harness, setHarness] = useState<HarnessFilter>("all");
  const [open, setOpen] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const searchId = useId();
  const index = useMemo(() => skillIndex(state), [state]);
  // The field answers each key at once; the list follows at the next idle frame, so typing never
  // waits on the rows.
  const deferredQuery = useDeferredValue(query);
  const shown = useMemo(() => filterSkills(index, deferredQuery, harness), [index, deferredQuery, harness]);
  const groups = useMemo(() => groupSkills(shown), [shown]);
  const unavailable = !loading && (state === null || !state.available);
  const any = index.skills.length > 0;
  const home = state?.home;

  const gesture = useCallback(
    async (key: string, work: SkillsRun) => {
      setBusy(key);
      setError(null);
      try {
        const reply = await onRun(work);
        if (reply.error) setError(skillsErrorText(reply.error));
        return reply;
      } finally {
        setBusy(null);
      }
    },
    [onRun],
  );
  const actions = useMemo<RowActions>(
    () => ({
      home,
      onToggle: (skill, enabled) => void gesture(skill.id, { action: "set_enabled", id: skill.id, enabled }),
      onOpen: (skill) => void gesture(skill.id, { action: "open", id: skill.id }),
      onReveal: (skill) => void gesture(skill.id, { action: "reveal", id: skill.id }),
    }),
    [home, gesture],
  );
  const expand = useCallback((id: string) => setOpen((now) => (now === id ? null : id)), []);

  return (
    <section className="group skills-card" data-card="skills" data-skills-layout={layout}>
      <h3 className="group-title">{t("settingsPage.skills.title")}</h3>
      <p className="row-help skills-help">{t("settingsPage.skills.help")}</p>
      {unavailable ? (
        <div className="rows">
          <div className="row" data-skills-unavailable="">
            <span className="row-help">{t("settingsPage.skills.unavailable")}</span>
          </div>
        </div>
      ) : (
        <>
          <div className="skills-toolbar">
            <label className="skills-search" htmlFor={searchId}>
              <Icon name="search" />
              <Input
                id={searchId}
                variant="plain"
                className="field"
                data-skills-search=""
                placeholder={t("settingsPage.skills.search")}
                aria-label={t("settingsPage.skills.search")}
                value={query}
                disabled={loading || !any}
                onChange={(event) => setQuery(event.currentTarget.value)}
                onKeyDown={(event) => {
                  if (event.key === "Escape" && query) {
                    event.preventDefault();
                    setQuery("");
                  }
                }}
              />
            </label>
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
            <div className="skills-chips" role="group" aria-label={t("settingsPage.skills.harness")}>
              {(["all", ...HARNESSES] as const).map((choice) => (
                <button
                  key={choice}
                  type="button"
                  className="skills-chip"
                  data-skills-harness={choice}
                  aria-pressed={harness === choice}
                  disabled={loading || !any}
                  onClick={() => setHarness(choice)}
                >
                  {choice === "all" ? t("settingsPage.skills.harnessAll") : harnessTitle(choice)}
                </button>
              ))}
            </div>
            <Button
              type="button"
              className="button skills-new"
              data-skills-action="new"
              aria-expanded={creating}
              disabled={loading}
              onClick={() => setCreating((now) => !now)}
            >
              {t("settingsPage.skills.newSkill")}
            </Button>
          </div>
          <div className="collapse skills-fold" data-open={creating ? "" : undefined} inert={!creating}>
            <div className="collapse-body">
              <NewSkillForm
                key={creating ? "open" : "closed"}
                state={state}
                busy={busy === "create"}
                onCancel={() => setCreating(false)}
                onCreate={async (draft) => {
                  const reply = await gesture("create", { action: "create", ...draft });
                  if (!reply.skill) return;
                  setCreating(false);
                  setOpen(reply.skill.id);
                  setSelected(reply.skill.id);
                  await gesture(reply.skill.id, { action: "open", id: reply.skill.id });
                }}
              />
            </div>
          </div>
          {loading ? (
            <SkillsSkeleton />
          ) : !any ? (
            <div className="rows">
              <div className="row" data-skills-empty="">
                <span className="row-help">{t("settingsPage.skills.empty")}</span>
              </div>
            </div>
          ) : shown.length === 0 ? (
            <div className="rows">
              <div className="row" data-skills-no-matches="">
                <span className="row-help">{t("settingsPage.skills.noMatches")}</span>
              </div>
            </div>
          ) : layout === "split" ? (
            <SkillsSplit
              shown={shown}
              selected={shown.find((skill) => skill.id === selected) ?? shown[0]!}
              onSelect={setSelected}
              busy={busy}
              actions={actions}
            />
          ) : (
            groups.map((entry) => (
              <div className="skills-harness" data-skills-harness-group={entry.harness} key={entry.harness}>
                <h4 className="skills-harness-title">{harnessTitle(entry.harness)}</h4>
                {entry.groups.map((group) => (
                  <div className="skills-group" data-skills-group={group.key} key={group.key}>
                    <GroupHeader group={group} state={state} home={home} />
                    <div className={layout === "tiles" ? "skills-tiles" : "rows"}>
                      {group.skills.map((skill) =>
                        layout === "tiles" ? (
                          <SkillTile key={skill.id} skill={skill} busy={busy === skill.id} actions={actions} />
                        ) : (
                          <SkillRow
                            key={skill.id}
                            skill={skill}
                            expanded={open === skill.id}
                            onExpand={expand}
                            busy={busy === skill.id}
                            actions={actions}
                          />
                        ),
                      )}
                    </div>
                  </div>
                ))}
              </div>
            ))
          )}
        </>
      )}
      {error && (
        <div className="row-error" role="alert" data-skills-error="">
          {error}
        </div>
      )}
    </section>
  );
}

/** The rows' gestures: one object for every row, unchanged while a gesture runs, so a gesture redraws
 * only the row it marks busy. */
type RowActions = {
  home: string | undefined;
  onToggle: (skill: Skill, enabled: boolean) => void;
  onOpen: (skill: Skill) => void;
  onReveal: (skill: Skill) => void;
};

/** A group's header: the scope, and the project's folder (with its path) or the plugin's name. */
function GroupHeader({ group, state, home }: { group: SkillGroup; state: SkillsState | null; home?: string }) {
  const source =
    group.scope === "project" && group.source
      ? projectName(state, group.source)
      : group.scope === "plugin" && group.source
        ? pluginName(group.source)
        : null;
  return (
    <div className="skills-group-title">
      <span>{source ? `${scopeTitle(group.scope)} · ${source}` : scopeTitle(group.scope)}</span>
      {group.scope === "project" && group.source && (
        <span className="row-help skills-group-path">{shortPath(group.source, home)}</span>
      )}
    </div>
  );
}

/** A row's quiet facts: its source tag, how it loads, Overridden and a problem. */
function SkillTags({ skill }: { skill: Skill }) {
  const mode = modeTitle(skill.mode);
  const tag = skill.scope === "plugin" && skill.plugin ? pluginName(skill.plugin) : scopeTitle(skill.scope);
  return (
    <span className="skills-tags">
      {skill.problem && (
        <span className="skills-tag" data-skills-problem={skill.problem}>
          <Icon name="warning" />
          {t(`settingsPage.skills.problem.${skill.problem}`)}
        </span>
      )}
      {skill.shadowed && (
        <span className="skills-tag" data-skills-shadowed="" title={t("settingsPage.skills.overriddenHelp")}>
          {t("settingsPage.skills.overridden")}
        </span>
      )}
      {mode && <span className="skills-tag">{mode}</span>}
      <span className="skills-tag" data-skills-tag="">
        {tag}
      </span>
    </span>
  );
}

/** The switch, when the daemon can turn the skill (or its plugin) on or off. */
function SkillSwitch({ skill, busy, actions }: { skill: Skill; busy: boolean; actions: RowActions }) {
  if (!skill.toggle) return null;
  const plugin = skill.toggle === "plugin" && skill.plugin ? pluginName(skill.plugin) : null;
  const label = plugin ? t("settingsPage.skills.togglePlugin", plugin) : t("settingsPage.skills.toggle", skill.name);
  const control = (
    <Switch
      nativeButton
      render={<button type="button" aria-label={label} />}
      size="sm"
      aria-label={label}
      data-skills-toggle={skill.toggle}
      checked={skill.enabled}
      disabled={busy}
      onCheckedChange={(next) => actions.onToggle(skill, next)}
    />
  );
  return plugin ? <Tooltip label={label}>{control}</Tooltip> : control;
}

/** Open in Editor and Show in Finder, as icon buttons named by their tooltips. */
function SkillButtons({ skill, actions }: { skill: Skill; actions: RowActions }) {
  return (
    <>
      <Tooltip label={t("settingsPage.skills.open")}>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          icon
          className="skills-icon-button"
          data-skills-action="open"
          aria-label={t("settingsPage.skills.open")}
          onClick={() => actions.onOpen(skill)}
        >
          <Icon name="square.and.pencil" />
        </Button>
      </Tooltip>
      <Tooltip label={t("settingsPage.skills.reveal")}>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          icon
          className="skills-icon-button"
          data-skills-action="reveal"
          aria-label={t("settingsPage.skills.reveal")}
          onClick={() => actions.onReveal(skill)}
        >
          <Icon name="folder" />
        </Button>
      </Tooltip>
    </>
  );
}

function description(skill: Skill): string {
  return skill.description || (skill.problem ? t(`settingsPage.skills.problem.${skill.problem}`) : "");
}

/** One dense row: name over its muted one-line description; the name unfolds the file and the full
 * description in place. Memoized: a filter keystroke redraws only rows whose props change. */
const SkillRow = memo(function SkillRow({
  skill,
  expanded,
  onExpand,
  busy,
  actions,
}: {
  skill: Skill;
  expanded: boolean;
  onExpand: (id: string) => void;
  busy: boolean;
  actions: RowActions;
}) {
  const detailId = useId();
  const text = description(skill);
  return (
    <div
      className="row skills-row"
      data-skill={skill.id}
      data-enabled={skill.enabled ? "true" : "false"}
      data-shadowed={skill.shadowed ? "" : undefined}
    >
      <div className="row-main">
        <button
          type="button"
          className="row-label skills-name"
          aria-expanded={expanded}
          aria-controls={detailId}
          data-skills-expand=""
          onClick={() => onExpand(skill.id)}
        >
          <span className="row-title">{skill.name}</span>
          <span className="row-help skills-description" title={text}>
            {text}
          </span>
        </button>
        <span className="row-control">
          <SkillTags skill={skill} />
          <SkillButtons skill={skill} actions={actions} />
          <SkillSwitch skill={skill} busy={busy} actions={actions} />
        </span>
      </div>
      <div
        className="collapse skills-fold"
        id={detailId}
        data-open={expanded ? "" : undefined}
        data-skills-detail=""
        inert={!expanded}
      >
        <div className="collapse-body skills-detail">
          <span className="row-key" data-skills-file="">
            {shortPath(skill.file, actions.home)}
          </span>
          {skill.description && <span className="skills-detail-text">{skill.description}</span>}
        </div>
      </div>
    </div>
  );
});

/** A tile (layout `tiles`): name, two lines of description, tags, the switch and the buttons. */
const SkillTile = memo(function SkillTile({
  skill,
  busy,
  actions,
}: {
  skill: Skill;
  busy: boolean;
  actions: RowActions;
}) {
  const text = description(skill);
  return (
    <div className="skills-tile" data-skill={skill.id} data-enabled={skill.enabled ? "true" : "false"}>
      <div className="skills-tile-head">
        <span className="row-title">{skill.name}</span>
        <SkillSwitch skill={skill} busy={busy} actions={actions} />
      </div>
      <span className="row-help skills-tile-description" title={text}>
        {text}
      </span>
      <div className="skills-tile-foot">
        <SkillTags skill={skill} />
        <span className="skills-tile-buttons">
          <SkillButtons skill={skill} actions={actions} />
        </span>
      </div>
    </div>
  );
});

/** Layout `split`: the names on the left, the selected skill on the right. */
function SkillsSplit({
  shown,
  selected,
  onSelect,
  busy,
  actions,
}: {
  shown: Skill[];
  selected: Skill;
  onSelect: (id: string) => void;
  busy: string | null;
  actions: RowActions;
}) {
  return (
    <div className="skills-split">
      <div className="skills-split-list">
        {shown.map((skill) => (
          <button
            key={skill.id}
            type="button"
            className="skills-split-item"
            data-skill={skill.id}
            data-enabled={skill.enabled ? "true" : "false"}
            aria-pressed={skill.id === selected.id}
            onClick={() => onSelect(skill.id)}
          >
            <span className="row-title">{skill.name}</span>
            <span className="row-help">
              {harnessTitle(skill.harness)} · {skill.plugin ? pluginName(skill.plugin) : scopeTitle(skill.scope)}
            </span>
          </button>
        ))}
      </div>
      <div className="skills-split-detail" data-skills-selected={selected.id}>
        <div className="skills-tile-head">
          <span className="row-title">{selected.name}</span>
          <SkillSwitch skill={selected} busy={busy === selected.id} actions={actions} />
        </div>
        <SkillTags skill={selected} />
        <span className="skills-detail-text">{description(selected)}</span>
        <span className="row-key">{shortPath(selected.file, actions.home)}</span>
        <span className="skills-tile-buttons">
          <SkillButtons skill={selected} actions={actions} />
        </span>
      </div>
    </div>
  );
}

/** While the first read is out: row-shaped blocks at the rows' own height, so the list lands without
 * moving anything. */
function SkillsSkeleton() {
  return (
    <div className="rows" data-skills-loading="" aria-busy="true" aria-label={t("settingsPage.skills.loading")}>
      {[0, 1, 2, 3].map((at) => (
        <div className="row skills-skeleton" key={at} aria-hidden="true">
          <span className="skills-skeleton-line" />
          <span className="skills-skeleton-line wide" />
        </div>
      ))}
    </div>
  );
}

type Draft = { harness: SkillHarness; scope: "user" | "project"; project?: string; name: string; description: string };

/** New Skill: harness, Personal or a listed project, a checked name and a description. */
function NewSkillForm({
  state,
  busy,
  onCancel,
  onCreate,
}: {
  state: SkillsState | null;
  busy: boolean;
  onCancel: () => void;
  onCreate: (draft: Draft) => Promise<void>;
}) {
  const [harness, setHarness] = useState<SkillHarness>("claude");
  const [where, setWhere] = useState("user");
  const [name, setName] = useState("");
  const [text, setText] = useState("");
  const ids = { harness: useId(), where: useId(), name: useId(), description: useId(), rule: useId() };
  const projects = state?.projects ?? [];
  const valid = validSkillName(name);
  const wrong = name.length > 0 && !valid;
  const submit = () => {
    if (!valid || busy) return;
    void onCreate({
      harness,
      ...(where === "user" ? { scope: "user" as const } : { scope: "project" as const, project: where }),
      name,
      description: text.trim(),
    });
  };
  return (
    <form
      className="skills-form"
      data-skills-form=""
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <div className="host-field">
        <span className="row-help" id={ids.harness}>
          {t("settingsPage.skills.harness")}
        </span>
        <Select
          value={harness}
          disabled={busy}
          labelId={ids.harness}
          onChange={(value) => setHarness(value as SkillHarness)}
        >
          {HARNESSES.map((choice) => (
            <option key={choice} value={choice}>
              {harnessTitle(choice)}
            </option>
          ))}
        </Select>
      </div>
      <div className="host-field">
        <span className="row-help" id={ids.where}>
          {t("settingsPage.skills.where")}
        </span>
        <Select value={where} disabled={busy} labelId={ids.where} onChange={setWhere}>
          <option value="user">{t("settingsPage.skills.scope.user")}</option>
          {projects.map((project) => (
            <option key={project.root} value={project.root}>
              {`${t("settingsPage.skills.scope.project")} · ${project.name}`}
            </option>
          ))}
        </Select>
      </div>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.skills.name")}</span>
        <Input
          id={ids.name}
          className="field"
          data-skills-field="name"
          value={name}
          maxLength={64}
          autoComplete="off"
          spellCheck={false}
          aria-invalid={wrong}
          aria-describedby={ids.rule}
          disabled={busy}
          onChange={(event) => setName(event.currentTarget.value)}
        />
      </label>
      <span className={wrong ? "field-error skills-rule" : "row-help skills-rule"} id={ids.rule} data-skills-rule="">
        {t("settingsPage.skills.nameRule")}
      </span>
      <label className="host-field">
        <span className="row-help">{t("settingsPage.skills.description")}</span>
        <Input
          id={ids.description}
          className="field"
          data-skills-field="description"
          value={text}
          placeholder={t("settingsPage.skills.descriptionHint")}
          disabled={busy}
          onChange={(event) => setText(event.currentTarget.value)}
        />
      </label>
      <div className="host-actions">
        <Button type="submit" className="button" data-skills-action="create" disabled={!valid || busy}>
          {t("settingsPage.skills.create")}
        </Button>
        <Button type="button" className="button" data-skills-action="cancel" onClick={onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </form>
  );
}
