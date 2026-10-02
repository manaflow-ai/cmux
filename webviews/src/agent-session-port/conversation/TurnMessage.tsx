// A Codex turn rendered from protocol data: the "Worked for" disclosure, the activity log
// (commentary, collapsible tool groups, expandable rows), the final answer and the cards
// that close the turn. Content comes from activity.ts / turnEnd.ts; which disclosures are
// open is UI state, kept here per turn and keyed by the stable ids the derivation assigns.
import type { ReactNode, RefCallback } from "react";
import { useDisclosure, type Disclosure } from "./useDisclosure";
import {
  deriveTurn,
  type ActivityIcon,
  type ActivityRow,
  type ActivityUnit,
  type DeriveOptions,
} from "./derive";
import { turnEnd, type TurnEndBlock } from "./turnEnd";
import { EditedFilesCard } from "./cards";
import { DiffBlock } from "./CodeBlock";
import { Markdown } from "./Markdown";
import {
  AssistantMessage,
  ToolGroup,
  ToolRow,
  UserMessage,
  WorkedFor,
  type TurnActionsKind,
} from "./messages";
import {
  ChevronDown,
  CommandKey,
  Copy,
  DiffFile,
  FileDoc,
  Folder,
  Globe,
  Magnifier,
  OpenBook,
  Pencil,
  StopSquare,
  TerminalSquare,
  ToolGroup as ToolGroupIcon,
} from "./icons";
import type { Turn } from "./protocol";

/* ---------------- Icons ---------------- */

const ICONS: Record<ActivityIcon, () => ReactNode> = {
  globe: () => <Globe size={16} strokeWidth={1.1} />,
  read: () => <OpenBook />,
  search: () => <Magnifier />,
  list: () => <Folder />,
  terminal: () => <TerminalSquare />,
  stopped: () => <StopSquare size={16} />,
  computer: () => <CommandKey />,
  tool: () => <ToolGroupIcon size={16} strokeWidth={1.2} />,
  edit: () => <Pencil size={16} strokeWidth={1.1} />,
  image: () => <FileDoc />,
};
const icon = (i: ActivityIcon) => (i === "globe" ? "globe" : ICONS[i]());

/* ---------------- Rows ---------------- */

function Stats({ additions, deletions }: { additions: number; deletions: number }) {
  return (
    <span className="cv-counts cv-tool__stats">
      <span className="cv-add">+{additions}</span> <span className="cv-del">-{deletions}</span>
    </span>
  );
}

function RowBody({ row }: { row: ActivityRow }) {
  const body = row.body;
  if (!body) return null;
  switch (body.kind) {
    case "shell":
      return (
        <div className="cv-shell">
          <div className="cv-shell__title">Shell</div>
          <div className="cv-shell__scroll">
            <pre className="cv-shell__command">$ {body.command}</pre>
            {body.output && (
              <pre className="cv-shell__output">{body.output.replace(/\n$/, "")}</pre>
            )}
          </div>
          {body.exitCode != null && <div className="cv-shell__exit">Exit code {body.exitCode}</div>}
        </div>
      );
    case "tool-output":
      return (
        <div className="cv-tool-output">
          {body.blocks.map((b, i) => (
            <div key={i} className="cv-tool-output__block">
              <div className="cv-tool-output__lang">plaintext</div>
              <pre className="cv-tool-output__text">{b}</pre>
            </div>
          ))}
        </div>
      );
    case "diff":
      return (
        <div className="cv-diff">
          <div className="cv-diff__head">
            <span className="cv-diff__name">{body.name}</span>
            <Stats additions={body.additions} deletions={body.deletions} />
            <Copy className="cv-diff__copy" size={14} />
          </div>
          <DiffBlock name={body.name} diff={body.diff} />
        </div>
      );
  }
}

/**
 * Disclosed content: mounted on first open (growing in from `@starting-style`) and kept
 * mounted, inert and collapsed, once closed, so closing animates too (conversation.css).
 */
function Reveal({
  open,
  mounted,
  className = "",
  scrollRef,
  children,
}: {
  open: boolean;
  mounted: boolean;
  className?: string;
  /** Callback ref of a scrolling reveal (a long group's rows). */
  scrollRef?: RefCallback<HTMLDivElement>;
  children: ReactNode;
}) {
  if (!open && !mounted) return null;
  return (
    <div
      ref={scrollRef}
      className={`cv-reveal ${className}${open ? "" : " is-closed"}`}
      inert={!open}
    >
      {children}
    </div>
  );
}

/** One activity row; rows with a body (output, diff) are disclosures. */
export function ActivityRowView({ row, disclosure }: { row: ActivityRow; disclosure: Disclosure }) {
  const open = disclosure.isOpen(row.key);
  const dim = row.detailTone === "dim" ? row.detail : undefined;
  const label =
    row.detail === undefined || dim !== undefined ? (
      row.verb
    ) : row.detailTone === "link" ? (
      <>
        {row.verb} <span className="cv-tool__link">{row.detail}</span>
      </>
    ) : (
      `${row.verb} ${row.detail}`
    );
  const verbOnly = row.body?.kind === "diff" && open ? `${row.verb} file` : null;
  return (
    <>
      <ToolRow
        icon={icon(row.icon)}
        tone={row.live ? "dim" : "strong"}
        live={row.live}
        onToggle={row.body ? () => disclosure.toggle(row.key) : undefined}
        chevron={row.body ? (open ? "down" : "hover") : undefined}
        anchor={row.key}
        trailing={row.stats && !verbOnly ? <Stats {...row.stats} /> : undefined}
        detail={dim}
      >
        {verbOnly ?? label}
      </ToolRow>
      <Reveal open={open} mounted={disclosure.wasOpen(row.key)}>
        <RowBody row={row} />
      </Reveal>
    </>
  );
}

/* ---------------- Units ---------------- */

/** Groups longer than this scroll inside a fixed-height list with a fade. */
const GROUP_ROWS_VISIBLE = 9;

/**
 * A long group's rows scroll inside a fixed height. A group listed in `scrolledToOpen` starts
 * scrolled down until its last open row's body ends at the list's bottom edge
 * (live-freestyle-edit-diff-expanded: the user scrolled the group down to the patch row
 * near its end and opened its diff). Row bodies paint asynchronously
 * (Pierre), so a ResizeObserver owned by this callback ref re-applies the offset until the
 * first user scroll gesture; the ref's cleanup disconnects it. No effects.
 */
const scrollToOpen: RefCallback<HTMLDivElement> = (el) => {
  if (!el) return;
  let released = false;
  // The last open row's body ends at the list's bottom edge.
  const apply = () => {
    const bodies = el.querySelectorAll<HTMLElement>(":scope > .cv-reveal:not(.is-closed)");
    const body = bodies[bodies.length - 1];
    if (released || !body) return;
    el.scrollTop += body.getBoundingClientRect().bottom - el.getBoundingClientRect().bottom;
  };
  const release = () => (released = true);
  apply();
  const ro = new ResizeObserver(apply);
  for (const child of Array.from(el.children)) ro.observe(child);
  el.addEventListener("wheel", release, { passive: true });
  el.addEventListener("pointerdown", release);
  return () => {
    ro.disconnect();
    el.removeEventListener("wheel", release);
    el.removeEventListener("pointerdown", release);
  };
};

function Unit({
  unit,
  disclosure,
  toOpen,
}: {
  unit: ActivityUnit;
  disclosure: Disclosure;
  /** A long group's rows start scrolled to its last open row (`scrolledToOpen`). */
  toOpen?: boolean;
}) {
  switch (unit.kind) {
    case "message":
      return <Markdown>{unit.text}</Markdown>;
    case "thinking":
      return (
        <ToolGroup>
          <ToolRow live>{unit.label}</ToolRow>
        </ToolGroup>
      );
    case "row":
      return (
        <ToolGroup>
          <ActivityRowView row={unit.row} disclosure={disclosure} />
        </ToolGroup>
      );
    case "group": {
      const open = disclosure.isOpen(unit.key);
      const long = unit.rows.length > GROUP_ROWS_VISIBLE;
      return (
        <ToolGroup>
          <ToolRow
            icon={icon(unit.icon)}
            tone="strong"
            chevron={open ? "down" : "hover"}
            onToggle={() => disclosure.toggle(unit.key)}
            anchor={unit.key}
          >
            {unit.label}
          </ToolRow>
          <Reveal
            open={open}
            mounted={disclosure.wasOpen(unit.key)}
            className={`cv-group-rows${long ? " is-scroll" : ""}`}
            scrollRef={long && toOpen ? scrollToOpen : undefined}
          >
            {unit.rows.map((r) => (
              <ActivityRowView key={r.key} row={r} disclosure={disclosure} />
            ))}
          </Reveal>
        </ToolGroup>
      );
    }
  }
}

/* ---------------- Turn end ---------------- */

/** "Web preview / Website" card with its "Open in" button (end-of-turn website resource). */
export function WebsiteCard({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="cv-resource">
      <span className="cv-resource__icon is-web">
        <Globe size={18} strokeWidth={1.1} />
      </span>
      <span className="cv-resource__text">
        <span className="cv-resource__title">{title}</span>
        <span className="cv-resource__subtitle">{subtitle}</span>
      </span>
      <span className="cv-resource__open">
        Open in <ChevronDown size={14} strokeWidth={1.2} />
      </span>
    </div>
  );
}

/** A file produced by the turn ("Document · pdf"). */
export function FileCard({ name, subtitle }: { name: string; subtitle: string }) {
  return (
    <div className="cv-resource">
      <span className="cv-resource__icon">
        <DiffFile size={18} strokeWidth={1.1} />
      </span>
      <span className="cv-resource__text">
        <span className="cv-resource__title">{name}</span>
        <span className="cv-resource__subtitle">{subtitle}</span>
      </span>
      <span className="cv-resource__open">
        Open in <ChevronDown size={14} strokeWidth={1.2} />
      </span>
    </div>
  );
}

function EndBlock({ block, visibleFiles }: { block: TurnEndBlock; visibleFiles?: number }) {
  switch (block.kind) {
    case "website":
      return <WebsiteCard title={block.title} subtitle={block.subtitle} />;
    case "file":
      return <FileCard name={block.name} subtitle={block.subtitle} />;
    case "edited-files":
      return <EditedFilesCard files={block.files} visible={visibleFiles} />;
  }
}

/* ---------------- Turn ---------------- */

export type TurnMessageProps = {
  turn: Turn;
  derive?: DeriveOptions;
  /** Disclosures open at first render (UI state, not content). */
  open?: readonly string[];
  /** Buttons closing the turn. */
  actions?: TurnActionsKind;
  /** Copy / edit buttons under the user bubble. */
  userActions?: boolean;
  /** Draw the user bubble (false when a screen starts mid-turn). */
  showUser?: boolean;
  /** Hairline under the "Worked for" row. */
  divider?: boolean;
  /** Files listed before "Show N more" in the edited-files card. */
  visibleFiles?: number;
  /**
   * Long groups (keys) whose rows start scrolled down to their last open row's body (UI
   * state, like `open`: where the user scrolled the group).
   */
  scrolledToOpen?: readonly string[];
};

/** One turn: user bubble, then the assistant side derived from the turn's items. */
export function TurnMessage({
  turn,
  derive,
  open,
  actions,
  userActions,
  showUser = true,
  divider,
  visibleFiles,
  scrolledToOpen,
}: TurnMessageProps) {
  const view = deriveTurn(turn, derive);
  const end = turnEnd(turn, derive);
  const disclosure = useDisclosure(open);
  const header = view.header;
  const expanded = !header?.collapsible || disclosure.isOpen(view.key);
  return (
    <>
      {showUser && view.user && <UserMessage actions={userActions}>{view.user.text}</UserMessage>}
      <AssistantMessage actions={actions}>
        {header && (
          <WorkedFor
            label={header.label}
            divider={divider}
            chevron={header.collapsible ? (expanded ? "down" : "right") : false}
            onToggle={header.collapsible ? () => disclosure.toggle(view.key) : undefined}
            anchor={view.key}
          />
        )}
        {view.activity.length > 0 &&
          (header?.collapsible ? (
            <Reveal
              open={expanded}
              mounted={disclosure.wasOpen(view.key)}
              className="cv-activity cv-reveal--turn"
            >
              {view.activity.map((u) => (
                <Unit
                  key={u.key}
                  unit={u}
                  disclosure={disclosure}
                  toOpen={scrolledToOpen?.includes(u.key)}
                />
              ))}
            </Reveal>
          ) : (
            <div className="cv-activity">
              {view.activity.map((u) => (
                <Unit
                  key={u.key}
                  unit={u}
                  disclosure={disclosure}
                  toOpen={scrolledToOpen?.includes(u.key)}
                />
              ))}
            </div>
          ))}
        {view.final.map((m) => (
          <Markdown key={m.key}>{m.text}</Markdown>
        ))}
        {end.map((b) => (
          <EndBlock key={b.key} block={b} visibleFiles={visibleFiles} />
        ))}
      </AssistantMessage>
    </>
  );
}
