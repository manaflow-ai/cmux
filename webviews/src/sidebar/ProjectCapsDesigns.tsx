// l10n-allow-file: gallery design fixtures for the native sidebar's project caps, not shipped UI.
// Leo decided the sidebar's caps on 2026-11-10 (projectCapsModel.ts has the rules). The native
// Swift sidebar implements them; this gallery picks the look of the three new pieces:
//   - the "Show N more" / "Show less" row at the end of a capped project,
//   - the project header that sticks while you scroll an expanded project (only a stuck header
//     collapses on click; it collapses the project and scrolls back to its top),
//   - the "Needs you" section at the very top.
// One scroll area, never a nested scroll box. Expanding and collapsing are state transitions: the
// rows a page reveals sit in a grid track that opens from 0fr to 1fr, so the rows below slide
// down together; nothing pops in and nothing jumps.
//
// Picks (each gallery entry's notes say "Pick."; no viewer pick until a tracker bead exists):
//   show-more "text": the quiet secondary-ink "Show 20 more" in the member text column with a
//     12 px chevron after it. It is the ChatGPT row Leo named, it names the count (a chip alone
//     reads as an unread badge on the trail column, where the blue dot and the spinner live) and
//     it keeps the trail column free; "Show less" uses the same row with the chevron turned up.
//   sticky "veil": a stuck header lies on the sidebar's own glass (the sidebar tone at 90% with a
//     blur) and fades into the rows over 12 px below it. No line, as the Blocks rule wants, and
//     no shadow, which would read as a card lifted above the glass.
import { useCallback, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { AgentMark } from "../agent-session/shared/AgentMark";
import { Spinner } from "../agent-session/acpmux/conversation/icons";
import { STATUS_UNREAD } from "../theme/statusColors";
import { capProjects } from "./projectCapsFixtures";
import { layoutProject, moreLabel, needsYou, type CapChat, type CapProject, type CapRow } from "./projectCapsModel";
import "./ProjectCapsDesigns.css";

export type ShowMoreStyle = "text" | "chip" | "dots" | "lead";
export type StickyStyle = "veil" | "shadow" | "label";
export type NeedsYouStyle = "rows" | "tinted";

export interface ProjectCapsDesignsProps {
  showMore?: ShowMoreStyle;
  sticky?: StickyStyle;
  /** Draw the Needs you section at the top. */
  needsYou?: NeedsYouStyle;
  /** Needs you starts collapsed to its header. */
  needsYouCollapsed?: boolean;
  /** Pages of "Show more" open at first, by project id (a number past the last opens everything). */
  open?: Record<string, number>;
  /** Projects to draw, by id; all of them when absent. */
  projects?: string[];
}

function Chevron({ up = false }: { up?: boolean }) {
  return (
    <svg className="pcd-chevron" data-up={up || undefined} viewBox="0 0 12 12" width="12" height="12" aria-hidden>
      <path
        d="M3 4.5 6 7.5 9 4.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function Pin() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden>
      <path
        d="M9.5 2.5 13.5 6.5 11 7.5 8.5 10l.5 3-6-6 3 .5L8.5 5Zm-6 10 3-3"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
}

function Trail({ chat }: { chat: CapChat }) {
  if (chat.state === "running") return <Spinner size={12} />;
  if (chat.state === "unread") return <span className="pcd-dot" data-tone="blue" />;
  if (chat.state === "waiting") return <span className="pcd-dot" data-tone="yellow" />;
  return <span className="pcd-age">{chat.age}</span>;
}

const stateWords: Record<CapChat["state"], string> = {
  idle: "",
  running: ", working",
  unread: ", unread",
  waiting: ", waiting on you",
};

function ChatRow({ chat }: { chat: CapChat }) {
  return (
    <div
      className="pcd-row"
      aria-selected={chat.selected || undefined}
      aria-label={`${chat.title}${stateWords[chat.state]}`}
    >
      <span className="pcd-lead">{chat.pinned ? <Pin /> : <AgentMark agent={chat.harness} size={16} reserve />}</span>
      <span className="pcd-title">{chat.title}</span>
      <span className="pcd-trail">
        <Trail chat={chat} />
      </span>
    </div>
  );
}

/** Rows a page reveals: a grid track that opens from 0fr to 1fr, so the rows below slide together. */
function Reveal({ open, children }: { open: boolean; children: ReactNode }) {
  return (
    <div
      className="pcd-reveal"
      data-open={open || undefined}
      inert={!open || undefined}
      aria-hidden={!open || undefined}
    >
      <div className="pcd-reveal-inner">{children}</div>
    </div>
  );
}

/** Consecutive rows that open with the same page, so a running row between them keeps its place. */
function runs(rows: readonly CapRow[]): { page: number; rows: CapRow[] }[] {
  const out: { page: number; rows: CapRow[] }[] = [];
  for (const row of rows) {
    const last = out[out.length - 1];
    if (last && last.page === row.page) last.rows.push(row);
    else out.push({ page: row.page, rows: [row] });
  }
  return out;
}

function MoreRow({
  style,
  label,
  onClick,
}: {
  style: ShowMoreStyle;
  label: NonNullable<ReturnType<typeof moreLabel>>;
  onClick: () => void;
}) {
  const less = label.kind === "less";
  const count = label.kind === "more" ? label.count : 0;
  let content: ReactNode;
  if (style === "text")
    content = (
      <>
        <span className="pcd-lead" />
        <span className="pcd-more-text">
          {less ? "Show less" : `Show ${count} more`}
          <Chevron up={less} />
        </span>
      </>
    );
  else if (style === "chip")
    content = (
      <>
        <span className="pcd-lead" />
        <span className="pcd-more-text">{less ? "Show less" : "Show more"}</span>
        <span className="pcd-trail">{less ? <Chevron up /> : <span className="pcd-chip">{count}</span>}</span>
      </>
    );
  else if (style === "dots")
    content = (
      <>
        <span className="pcd-lead pcd-more-glyph">{less ? <Chevron up /> : "···"}</span>
        <span className="pcd-more-text">{less ? "Show less" : `${count} more`}</span>
      </>
    );
  else content = <span className="pcd-more-text pcd-more-on-lead">{less ? "Show less" : "Show more"}</span>;
  return (
    <button type="button" className="pcd-row pcd-more" data-style={style} onClick={onClick} aria-expanded={less}>
      {content}
    </button>
  );
}

function Project({
  project,
  showMore,
  sticky,
  stuck,
  initialOpen,
  scroller,
}: {
  project: CapProject;
  showMore: ShowMoreStyle;
  sticky: StickyStyle;
  stuck: boolean;
  initialOpen: number;
  scroller: () => HTMLElement | null;
}) {
  const layout = useMemo(() => layoutProject(project.chats), [project]);
  const [open, setOpen] = useState(Math.min(initialOpen, layout.pages));
  const section = useRef<HTMLElement>(null);
  const label = moreLabel(layout, open);
  // Only a stuck header collapses its project; at rest the header is a plain title.
  const collapsible = stuck && open > 0;
  const collapse = useCallback(() => {
    const element = section.current;
    const scroll = scroller();
    if (element && scroll && element.offsetTop < scroll.scrollTop)
      scroll.scrollTo({ top: element.offsetTop, behavior: "smooth" });
    setOpen(0);
  }, [scroller]);
  return (
    <section
      ref={section}
      className="pcd-project"
      data-project={project.id}
      data-sticky={sticky}
      data-stuck={stuck || undefined}
      aria-label={project.name}
    >
      <button
        type="button"
        className="pcd-header"
        onClick={collapsible ? collapse : undefined}
        aria-label={collapsible ? `${project.name}, collapse` : project.name}
      >
        <span className="pcd-header-text">{project.name}</span>
        {collapsible && (
          <span className="pcd-header-trail">
            <Chevron up />
          </span>
        )}
      </button>
      {runs(layout.rows).map((run) =>
        run.page === 0 ? (
          run.rows.map((row) => <ChatRow key={row.chat.id} chat={row.chat} />)
        ) : (
          <Reveal key={run.rows[0]!.chat.id} open={run.page <= open}>
            {run.rows.map((row) => (
              <ChatRow key={row.chat.id} chat={row.chat} />
            ))}
          </Reveal>
        ),
      )}
      {label && (
        <MoreRow
          style={showMore}
          label={label}
          onClick={() => (label.kind === "less" ? collapse() : setOpen(open + 1))}
        />
      )}
    </section>
  );
}

function NeedsYou({ style, collapsed }: { style: NeedsYouStyle; collapsed: boolean }) {
  const { shown, rest, more } = needsYou(capProjects);
  const [folded, setFolded] = useState(collapsed);
  const [all, setAll] = useState(false);
  const total = shown.length + more;
  if (total === 0) return null;
  return (
    <section className="pcd-needs" data-style={style} aria-label="Needs you">
      <button
        type="button"
        className="pcd-header pcd-needs-header"
        onClick={() => setFolded(!folded)}
        aria-expanded={!folded}
      >
        <span className="pcd-header-text">Needs you</span>
        <span className="pcd-header-trail">{folded ? <span className="pcd-chip">{total}</span> : <Chevron up />}</span>
      </button>
      <Reveal open={!folded}>
        {shown.map((chat) => (
          <ChatRow key={chat.id} chat={chat} />
        ))}
        {more > 0 && (
          <>
            <Reveal open={all}>
              {rest.map((chat) => (
                <ChatRow key={chat.id} chat={chat} />
              ))}
            </Reveal>
            <button
              type="button"
              className="pcd-row pcd-more"
              data-style="text"
              onClick={() => setAll(!all)}
              aria-expanded={all}
            >
              <span className="pcd-lead" />
              <span className="pcd-more-text">
                {all ? "Show less" : `${more} more`}
                <Chevron up={all} />
              </span>
            </button>
          </>
        )}
      </Reveal>
    </section>
  );
}

/** The theme's unread blue, else the status set's own (the gallery theme may not publish it). */
const unreadTint = { "--pcd-blue": `var(--cmux-status-unread, ${STATUS_UNREAD})` } as CSSProperties;

export function ProjectCapsDesigns({
  showMore = "text",
  sticky = "veil",
  needsYou: needsYouStyle,
  needsYouCollapsed = false,
  open = {},
  projects,
}: ProjectCapsDesignsProps) {
  const scroll = useRef<HTMLDivElement>(null);
  const scroller = useCallback(() => scroll.current, []);
  const [stuck, setStuck] = useState<string | null>(null);
  const shownProjects = projects ? capProjects.filter((project) => projects.includes(project.id)) : capProjects;
  // On scroll: the header that is stuck now (its project's top is above the scroll top, its end below).
  const measure = useCallback(() => {
    const element = scroll.current;
    if (!element) return;
    let id: string | null = null;
    for (const section of element.querySelectorAll<HTMLElement>(".pcd-project")) {
      const header = section.querySelector<HTMLElement>(".pcd-header");
      if (
        section.offsetTop < element.scrollTop &&
        section.offsetTop + section.offsetHeight - (header?.offsetHeight ?? 0) > element.scrollTop
      )
        id = section.dataset.project ?? null;
    }
    setStuck(id);
  }, []);
  return (
    <div className="pcd-sidebar" style={unreadTint}>
      <div ref={scroll} className="pcd-scroll" onScroll={measure}>
        {needsYouStyle && <NeedsYou style={needsYouStyle} collapsed={needsYouCollapsed} />}
        {shownProjects.map((project) => (
          <Project
            key={project.id}
            project={project}
            showMore={showMore}
            sticky={sticky}
            stuck={stuck === project.id}
            initialOpen={open[project.id] ?? 0}
            scroller={scroller}
          />
        ))}
      </div>
    </div>
  );
}
