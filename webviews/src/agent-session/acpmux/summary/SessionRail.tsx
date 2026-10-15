// The session side rail (cx-ncc.101, Debug Settings `agent.sessionRail`; Claude Code desktop's right rail): a column
// beside the chat with where the session runs and its folders (Environment), how much of the
// context window it used (Context) and the files it created or changed (Outputs), each opening its
// diff. A header button shows and hides it. It reads only acpmux's common snapshot (the summary and
// the rows), never one harness's fields. With the flag off the pane has neither the button nor the
// rail. Connectors wait for acpmux to report each session's MCP servers (cx-ncc.105); Remote Control
// is Claude-only and stays out (Leo, 2026-10-14).
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Disclosure } from "../../../ui/Disclosure";
import { Counts } from "../changes/Counts";
import type { TurnFile } from "../diff";
import { useHeaderState } from "../header/headerState";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSnapshot } from "../model";
import { homePath, projectLabel } from "../sessionList";
import { sessionSummary } from "./sessionSummary";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
type CardId = "environment" | "context" | "connectors" | "outputs";
type Cards = Record<CardId, boolean>;

const ROW_ICON = rowIconSize(12);
/// Environment and Outputs start open, Context and Connectors folded to their counts (as in Claude
/// Code desktop).
const DEFAULT_CARDS: Cards = { environment: true, context: false, connectors: false, outputs: true };
/// The last open or closed, a per-viewer convenience: each pane keeps its own in state.
const OPEN_KEY = "cmux.agentPane.sessionRail.open";
/// Where the rail stops sitting beside the chat and covers it (summary.css `.acpmux-rail` overlay).
const OVERLAY_QUERY = "(max-width:560px)";
/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;

function readOpen(): boolean {
  try {
    return window.localStorage.getItem(OPEN_KEY) === "1";
  } catch {
    return false;
  }
}

function saveOpen(open: boolean) {
  try {
    window.localStorage.setItem(OPEN_KEY, open ? "1" : "0");
  } catch {
    // Storage off (a private window): the pane's state still holds it.
  }
}

/// The header button and the rail for the chat's pane, or neither while the Debug Settings toggle is off. The
/// App puts the button in the header's actions and the rail beside the chat column.
export function useSessionRail({
  snapshot,
  machineName,
  onOpenOutput,
}: {
  snapshot: AcpmuxSnapshot;
  /// This Mac's name from the handshake, for a local session.
  machineName?: string;
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
}): { button?: ReactNode; rail?: ReactNode } {
  const t = useT();
  const enabled = useHeaderState().sessionRail;
  const [open, setOpen] = useState(readOpen);
  const [cards, setCards] = useState<Cards>(DEFAULT_CARDS);
  const shown = enabled && open;
  const rows = snapshot.rows;
  const outputs = useMemo(() => (shown ? sessionSummary(rows).outputs : []), [shown, rows]);
  // An output's diff opens beside the chat. When that split leaves the pane too narrow for the
  // rail beside the chat, the rail would cover the chat, so it closes for now (not remembered).
  const openedOutputAt = useRef(0);
  useEffect(() => {
    if (!shown || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(OVERLAY_QUERY);
    const narrowed = () => {
      if (query.matches && Date.now() - openedOutputAt.current < SPLIT_SETTLE_MS) setOpen(false);
    };
    query.addEventListener("change", narrowed);
    return () => query.removeEventListener("change", narrowed);
  }, [shown]);
  if (!enabled) return {};
  const openOutput = onOpenOutput
    ? (path: string) => {
        openedOutputAt.current = Date.now();
        onOpenOutput(path);
      }
    : undefined;
  const toggle = () => {
    saveOpen(!open);
    setOpen(!open);
  };
  return {
    button: (
      <button
        type="button"
        className="acpmux-header-tool"
        aria-label={t("rail.toggle")}
        aria-pressed={open}
        title={t("rail.toggle")}
        onClick={toggle}
      >
        <Icon name="pane.split.right" size={15} />
      </button>
    ),
    rail: shown ? (
      <SessionRail
        summary={snapshot.summary}
        machineName={machineName}
        outputs={outputs}
        cards={cards}
        onCard={(id, next) => setCards((current) => ({ ...current, [id]: next }))}
        onOpenOutput={openOutput}
      />
    ) : undefined,
  };
}

/// The rail's cards for one session: Environment, Context and Outputs.
export function SessionRail({
  summary,
  machineName,
  outputs,
  cards = DEFAULT_CARDS,
  onCard,
  onOpenOutput,
}: {
  summary?: Summary;
  machineName?: string;
  outputs: readonly TurnFile[];
  /// Which cards are open; uncontrolled without `onCard`.
  cards?: Cards;
  onCard?: (id: CardId, open: boolean) => void;
  onOpenOutput?: (path: string) => void;
}) {
  const t = useT();
  const [own, setOwn] = useState(cards);
  const state = onCard ? cards : own;
  const fold = (id: CardId) => (next: boolean) =>
    onCard ? onCard(id, next) : setOwn((current) => ({ ...current, [id]: next }));
  const usage = summary?.usage;
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  return (
    <aside className="acpmux-rail" aria-label={t("rail.toggle")}>
      <RailCard title={t("rail.environment")} open={state.environment} onOpenChange={fold("environment")}>
        <Environment summary={summary} machineName={machineName} />
      </RailCard>
      <RailCard
        title={t("rail.context")}
        open={known && state.context}
        onOpenChange={known ? fold("context") : undefined}
        meta={
          known ? (
            <>
              <span className="acpmux-rail-card__value">{t("rail.percent", { percent })}</span>
              <span className="acpmux-rail-meter" aria-hidden="true">
                <span style={{ width: `${percent}%` }} />
              </span>
            </>
          ) : (
            <span className="acpmux-rail-card__value">—</span>
          )
        }
      >
        {known && (
          <p className="acpmux-rail-note">
            {t("context.tokens", { used: tokens.format(usage.used), size: tokens.format(usage.size) })}
          </p>
        )}
      </RailCard>
      {summary?.mcpServers && summary.mcpServers.length > 0 && (
        <RailCard
          title={t("rail.connectors")}
          open={state.connectors}
          onOpenChange={fold("connectors")}
          meta={
            <span className="acpmux-rail-card__value">
              {t("rail.connected", {
                count: summary.mcpServers.filter((server) => server.status === "connected").length,
              })}
            </span>
          }
        >
          <Connectors servers={summary.mcpServers} />
        </RailCard>
      )}
      <RailCard title={t("rail.outputs")} open={state.outputs} onOpenChange={fold("outputs")}>
        {outputs.length > 0 ? (
          <ul className="acpmux-rail-list">
            {outputs.map((file) => (
              <li key={file.path}>
                <OutputRow file={file} onOpen={onOpenOutput} />
              </li>
            ))}
          </ul>
        ) : (
          <p className="acpmux-rail-note">{t("rail.noOutputs")}</p>
        )}
      </RailCard>
    </aside>
  );
}

/// A card: its title with a disclosure triangle and an optional value on the right; folds its body.
/// Without `onOpenChange` the header is plain text (Context before the agent reports usage).
function RailCard({
  title,
  open,
  onOpenChange,
  meta,
  children,
}: {
  title: string;
  open: boolean;
  onOpenChange?: (open: boolean) => void;
  meta?: ReactNode;
  children?: ReactNode;
}) {
  const head = (foldable: boolean) => (
    <>
      <span className="acpmux-rail-card__title">{title}</span>
      {foldable && (
        <Icon
          name={open ? "disclosure.expanded" : "disclosure.collapsed"}
          size={10}
          className="acpmux-rail-card__fold"
        />
      )}
      {meta && <span className="acpmux-rail-card__meta">{meta}</span>}
    </>
  );
  return (
    <section className="acpmux-rail-card">
      {onOpenChange ? (
        <Disclosure label={head(true)} open={open} onOpenChange={onOpenChange} className="acpmux-rail-card__disclosure">
          {children}
        </Disclosure>
      ) : (
        <div className="acpmux-rail-card__head">{head(false)}</div>
      )}
    </section>
  );
}

/// The folder's name, then its parent folder, home-abbreviated: `atlas-web` · `~/src`.
function splitFolder(path: string): { name: string; parent?: string } {
  const trimmed = path.replace(/\/+$/, "");
  const cut = trimmed.lastIndexOf("/");
  const parent = cut > 0 ? homePath(trimmed.slice(0, cut)) : undefined;
  return { name: projectLabel(trimmed), parent: parent && parent !== trimmed ? parent : undefined };
}

/// Where the session runs, as the composer's computer chip names it (ComposerContext computerId):
/// a peer or a Cloud host is another machine, else it is this Mac, by its name when known.
function Environment({ summary, machineName }: { summary?: Summary; machineName?: string }) {
  const t = useT();
  const remote = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
  const place = remote
    ? { icon: summary?.hostKind === "cloud" ? "cloud" : "machine.remote", name: summary?.host ?? remote }
    : {
        icon: "machine.local",
        name: machineName || (summary?.hostKind === "local" && summary.host ? summary.host : t("composer.thisMac")),
      };
  const cwd = summary?.cwd;
  const worktree = summary?.worktree && summary.worktree !== cwd ? summary.worktree : undefined;
  const folderRow = (path: string, icon: string) => {
    const { name, parent } = splitFolder(path);
    return (
      <li className="acpmux-rail-row">
        <Icon name={icon} size={ROW_ICON} row />
        <span className="acpmux-rail-row__name">{name}</span>
        {parent && (
          <>
            <span className="acpmux-rail-row__detail" aria-hidden="true">
              ·
            </span>
            <span className="acpmux-rail-row__detail">{parent}</span>
          </>
        )}
      </li>
    );
  };
  return (
    <ul className="acpmux-rail-list">
      <li className="acpmux-rail-row">
        <Icon name={place.icon} size={ROW_ICON} row />
        <span className="acpmux-rail-row__name">{place.name}</span>
      </li>
      {cwd && folderRow(cwd, cwd === summary?.worktree ? "git.worktree" : "folder")}
      {worktree && folderRow(worktree, "git.worktree")}
      {summary?.branch && (
        <li className="acpmux-rail-row">
          <Icon name="git.branch" size={ROW_ICON} row />
          <span className="acpmux-rail-row__name">{summary.branch}</span>
        </li>
      )}
    </ul>
  );
}

/// The MCP servers the harness says it loaded (acpmux `mcpServers`), each with its state when it
/// is not connected. Only harnesses that report them have the card (Claude Code today).
function Connectors({ servers }: { servers: NonNullable<Summary["mcpServers"]> }) {
  const t = useT();
  return (
    <ul className="acpmux-rail-list">
      {servers.map((server) => (
        <li key={server.name} className="acpmux-rail-row">
          <Icon name="extension" size={ROW_ICON} row />
          <span className="acpmux-rail-row__name">{server.name}</span>
          {server.status !== "connected" && (
            <span className={`acpmux-rail-row__state is-${server.status}`}>
              {t(server.status === "failed" ? "rail.connectorFailed" : "rail.connectorPending")}
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}

/// A file the session wrote: its icon, name and folder, and its line counts; a click opens its diff.
function OutputRow({ file, onOpen }: { file: TurnFile; onOpen?: (path: string) => void }) {
  const cut = file.displayPath.lastIndexOf("/");
  const name = cut >= 0 ? file.displayPath.slice(cut + 1) : file.displayPath;
  const folder = cut > 0 ? file.displayPath.slice(0, cut) : undefined;
  return (
    <button
      type="button"
      className="acpmux-rail-row acpmux-rail-output"
      disabled={!onOpen}
      onClick={() => onOpen?.(file.path)}
    >
      <Icon name={file.created ? "file.new" : "file.text"} size={ROW_ICON} row />
      <span className="acpmux-rail-row__name">{name}</span>
      {folder && <span className="acpmux-rail-row__detail">{folder}</span>}
      {!file.binary && <Counts additions={file.additions} deletions={file.deletions} />}
    </button>
  );
}
