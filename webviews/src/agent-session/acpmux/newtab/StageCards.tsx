// The cards over the New Tab composer (Leo 2026-10-19, Claude Code desktop's new-session screen):
// the composer sits at the foot of the page, and the empty space above it holds, centered, one card
// that picks where the chat starts and, under it, one card of suggested actions. Rows are plain
// text with an icon; only a hovered or focused row draws a wash, never a resting pill.
import { Tooltip } from "../../../ui/Tooltip";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { ProjectBadge } from "../ProjectBadge";
import { ProjectChooser, type Project } from "../ProjectChooser";
import { projectRows } from "../projectRepos";
import { isAgentHome } from "../sessionList";
import type { ChatCard } from "./screenModel";
import { useNt } from "./strings";

/// How many of this Mac's other projects the card lists before Choose environment.
const OTHER_PROJECTS = 3;

/// The environment card: the chat's project checked (or No project), this Mac's other recent
/// projects, then a divider and Choose environment, which opens every project with a search, a
/// typed path, Browse and No project (ProjectChooser).
export function EnvironmentCard({
  projects,
  current,
  noProject,
  machineName,
  onPick,
  onNoProject,
  onBrowse,
}: {
  projects: Project[];
  /// The folder the chat starts in, if any.
  current?: string;
  noProject: boolean;
  machineName?: string;
  onPick(cwd: string): void;
  onNoProject(): void;
  onBrowse?(): void;
}) {
  const t = useT();
  const nt = useNt();
  // A chat with no project runs in a private agent-home folder (sessionList.ts isAgentHome); it is
  // no environment to offer, as recentProjects keeps it out too.
  // One row per repository: a lane's checkout or scratch folder is no project to offer here.
  const local = projectRows(
    projects.filter((project) => !project.peer && !isAgentHome(project.cwd)),
    current,
  );
  const shown = current ? local.find((project) => project.cwd === current) : undefined;
  const others = local.filter((project) => project.cwd !== current).slice(0, OTHER_PROJECTS);
  const where = machineName ?? t("composer.thisMac");
  const head: Project | undefined = shown ?? (current ? { cwd: current, label: labelOf(current) } : undefined);
  return (
    <section className="nt-stage-card nt-env" aria-label={nt("env.label")}>
      {noProject ? (
        <button type="button" className="nt-stage-row" aria-pressed="true" onClick={onNoProject}>
          <span className="nt-stage-icon" aria-hidden="true">
            <Icon name="folder" size={14} />
          </span>
          <span className="nt-stage-text">{t("composer.noProject")}</span>
          <span className="nt-stage-check" aria-hidden="true">
            ✓
          </span>
        </button>
      ) : (
        head && <ProjectRow project={head} where={where} checked onPick={onPick} />
      )}
      {!current && !noProject && local.length === 0 && onBrowse && (
        // On a clean install there are no recent folders to show. Put the native folder picker
        // in the card so choosing the first project is one click instead of a menu hunt.
        <button type="button" className="nt-stage-row" data-action="browse-project" onClick={onBrowse}>
          <span className="nt-stage-icon" aria-hidden="true">
            <Icon name="folder" size={14} />
          </span>
          <span className="nt-stage-text">{t("project.browse")}</span>
        </button>
      )}
      {!current && !noProject && local.length === 0 && (
        // A fresh workspace has no recent project row yet. Keep the no-project path visible in
        // the card itself so a first chat can start without first discovering the chooser menu.
        <button type="button" className="nt-stage-row" aria-pressed={false} onClick={onNoProject}>
          <span className="nt-stage-icon" aria-hidden="true">
            <Icon name="folder" size={14} />
          </span>
          <span className="nt-stage-text">{t("composer.noProject")}</span>
        </button>
      )}
      {others.map((project) => (
        <ProjectRow key={project.cwd} project={project} where={where} checked={false} onPick={onPick} />
      ))}
      <hr className="nt-stage-divider" />
      <span className="nt-env-choose">
        <ProjectChooser
          inline
          side="bottom"
          projects={projects}
          {...(current ? { current } : {})}
          currentLabel={nt("env.choose")}
          icon={<Icon name="folder" size={14} />}
          onPick={(cwd) => onPick(cwd)}
          {...(onBrowse ? { onBrowse } : {})}
          onNoProject={onNoProject}
          noProject={noProject}
        />
      </span>
    </section>
  );
}

function ProjectRow({
  project,
  where,
  checked,
  onPick,
}: {
  project: Project;
  where: string;
  checked: boolean;
  onPick(cwd: string): void;
}) {
  return (
    <button
      type="button"
      className="nt-stage-row"
      aria-pressed={checked}
      // tooltip-allow: the row shows the folder's name; the tooltip is its whole path
      title={project.cwd}
      onClick={() => onPick(project.cwd)}
    >
      <span className="nt-stage-icon" aria-hidden="true">
        <ProjectBadge project={project} />
      </span>
      <span className="nt-stage-text">{project.label}</span>
      <span className="nt-stage-detail">{where}</span>
      <span className="nt-stage-check" aria-hidden="true">
        {checked ? "✓" : ""}
      </span>
    </button>
  );
}

function labelOf(cwd: string): string {
  const parts = cwd.replace(/\/+$/, "").split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

/// The suggested actions card: the chats waiting on the user (needs input, failed, lost its agent),
/// then New terminal, New browser tab and New chat (cx-ag5.7), as icon and text rows.
export function SuggestionsCard({
  attention,
  onOpen,
  onCreate,
  onChat,
}: {
  attention: ChatCard[];
  onOpen(sessionId: string): void;
  /// A blank terminal or browser tab; absent where the page cannot open one.
  onCreate?: (kind: "terminal" | "browser") => void;
  onChat(): void;
}) {
  const t = useT();
  const nt = useNt();
  return (
    <section className="nt-stage-card nt-suggest" aria-label={nt("suggest.label")}>
      {attention.map((card) => {
        const state =
          card.state === "failed"
            ? t("header.failed")
            : nt(`card.${card.state as "input" | "running" | "error" | "unread"}`);
        return (
          // A cut row's hover card shows the chat's whole title and what it waits on (Leo
          // 2026-10-19): a floating card over the page, offset from the row, never over its text.
          // tooltip-allow: the hover card is the cut title's whole text and the chat's wait
          <Tooltip
            key={card.sessionId}
            side="top"
            className="ui-card ui-glass nt-hovercard"
            label={
              <span className="nt-hovercard-body">
                <span className="nt-hovercard-title">{card.title}</span>
                <span className="nt-hovercard-detail">{card.message ?? state}</span>
              </span>
            }
          >
            <button
              type="button"
              className="nt-stage-row nt-suggest-chat"
              data-state={card.state}
              onClick={() => onOpen(card.sessionId)}
            >
              <span className="nt-stage-icon" aria-hidden="true">
                <Icon name="agent.chat" size={14} />
              </span>
              <span className="nt-stage-text">{card.title}</span>
              <span className="nt-stage-detail nt-suggest-state">{state}</span>
            </button>
          </Tooltip>
        );
      })}
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
      <div className="nt-create" role="group" aria-label={nt("create.label")}>
        {onCreate && (
          <>
            <button
              type="button"
              className="nt-stage-row nt-tool"
              data-create="terminal"
              onClick={() => onCreate("terminal")}
            >
              <span className="nt-stage-icon" aria-hidden="true">
                <Icon name="terminal" size={14} />
              </span>
              <span className="nt-stage-text">{nt("create.terminal")}</span>
            </button>
            <button
              type="button"
              className="nt-stage-row nt-tool"
              data-create="browser"
              onClick={() => onCreate("browser")}
            >
              <span className="nt-stage-icon" aria-hidden="true">
                <Icon name="browser" size={14} />
              </span>
              <span className="nt-stage-text">{nt("create.browser")}</span>
            </button>
          </>
        )}
        <button type="button" className="nt-stage-row nt-tool" data-create="chat" onClick={onChat}>
          <span className="nt-stage-icon" aria-hidden="true">
            <Icon name="agent.chat" size={14} />
          </span>
          <span className="nt-stage-text">{nt("create.chat")}</span>
        </button>
      </div>
    </section>
  );
}
