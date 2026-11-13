// The Agent Board page (cmux-page://cmux.agent-board/): every agent's work-tracking ledger, in the
// Matrix design picked from the prototype (2026-11-13): each capability is a grid of the states the
// agent built, the proof in each cell, and the decisions it made below. Off until the person turns
// it on here or in Settings, after reading what it costs.
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Dialog, DialogDescription, DialogTitle } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import {
  axesLabel,
  coverage,
  isStale,
  permutationsFor,
  type Board,
  type CapabilityRecord,
  type DecisionRecord,
  type EvidenceRecord,
  type PermutationRecord,
} from "./ledger";
import { failureMessage, type AgentBoardStore, type AgentLedger } from "./store";
import type { EvidenceImage } from "./types";

type Props = { store: AgentBoardStore; strings: Strings };

export function AgentBoardPage({ store, strings }: Props) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  if (snapshot.unavailable) return <p className="ab-message">{t("agentBoard.unavailable")}</p>;
  if (!snapshot.loaded) return <Loading strings={strings} />;
  if (snapshot.failed && snapshot.agents.length === 0)
    return (
      <section className="ab-message" role="alert">
        <p>{snapshot.failed.message ?? t("agentBoard.failed")}</p>
        <button
          type="button"
          className="ui-button ui-btn"
          data-variant="subtle"
          data-size="md"
          onClick={() => void store.refresh()}
        >
          {t("agentBoard.retry")}
        </button>
      </section>
    );
  if (!snapshot.enabled) return <Onboarding store={store} strings={strings} />;
  if (snapshot.agents.length === 0) return <Waiting store={store} strings={strings} folder={snapshot.folder} />;
  return (
    <BoardView
      store={store}
      strings={strings}
      agents={snapshot.agents}
      readAtMs={snapshot.readAtMs}
      stale={snapshot.failed ? (snapshot.failed.message ?? t("agentBoard.failed")) : undefined}
    />
  );
}

// MARK: - Off

function Onboarding({ store, strings }: Props) {
  const { t } = strings;
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string>();
  const confirm = useRef<HTMLButtonElement>(null);
  return (
    <section className="ab-onboard" aria-labelledby="ab-onboard-title">
      <div>
        <p className="ab-eyebrow">{t("agentBoard.onboard.eyebrow")}</p>
        <h1 id="ab-onboard-title">{t("agentBoard.onboard.title")}</h1>
        <p className="ab-lede">{t("agentBoard.onboard.lede")}</p>
        <ul className="ab-points">
          {(["decisions", "permutations", "evidence"] as const).map((point) => (
            <li key={point}>
              <strong>{t(`agentBoard.onboard.${point}.title`)}</strong> {t(`agentBoard.onboard.${point}.body`)}
            </li>
          ))}
        </ul>
        <div className="ab-cost" role="note">
          <h2>{t("agentBoard.cost.title")}</h2>
          <ol>
            <li>
              <strong>{t("agentBoard.cost.skill.title")}</strong> {t("agentBoard.cost.skill.body")}
            </li>
            <li>
              <strong>{t("agentBoard.cost.work.title")}</strong> {t("agentBoard.cost.work.body")}
            </li>
          </ol>
          <p className="ab-cost-foot">{t("agentBoard.cost.scope")}</p>
        </div>
        <div className="ab-actions">
          <button
            type="button"
            className="ui-button ui-btn ab-cta"
            data-variant="solid"
            data-size="md"
            onClick={() => setOpen(true)}
          >
            {t("agentBoard.turnOn")}
          </button>
          <span className="ab-hint">{t("agentBoard.onboard.settingHint")}</span>
        </div>
        {error && (
          <p className="ab-error" role="alert">
            {error}
          </p>
        )}
      </div>
      <Dialog
        open={open}
        onOpenChange={setOpen}
        className="ab-dialog"
        label={t("agentBoard.dialog.title")}
        initialFocus={confirm}
      >
        <form
          onSubmit={(event) => {
            event.preventDefault();
            setOpen(false);
            setError(undefined);
            store
              .setEnabled(true)
              .catch((reason: unknown) => setError(failureMessage(reason) ?? t("agentBoard.failed")));
          }}
        >
          <DialogTitle className="ab-dialog-title">{t("agentBoard.dialog.title")}</DialogTitle>
          <DialogDescription className="ab-dialog-body">{t("agentBoard.dialog.body")}</DialogDescription>
          <div className="ab-dialog-actions">
            <DialogButton
              dialogKey="escape"
              className="ui-button ui-btn"
              data-variant="subtle"
              data-size="md"
              onClick={() => setOpen(false)}
            >
              {t("agentBoard.dialog.cancel")}
            </DialogButton>
            <DialogButton
              ref={confirm}
              dialogKey="return"
              type="submit"
              className="ui-button ui-btn"
              data-variant="solid"
              data-size="md"
            >
              {t("agentBoard.dialog.confirm")}
            </DialogButton>
          </div>
        </form>
      </Dialog>
    </section>
  );
}

// MARK: - On, nothing yet

function Waiting({ store, strings, folder }: Props & { folder: string }) {
  const { t } = strings;
  return (
    <section className="ab-waiting" aria-labelledby="ab-waiting-title">
      <p className="ab-eyebrow">{t("agentBoard.waiting.eyebrow")}</p>
      <h1 id="ab-waiting-title">{t("agentBoard.waiting.title")}</h1>
      <p className="ab-lede">{t("agentBoard.waiting.body")}</p>
      <ol className="ab-steps">
        <li>{t("agentBoard.waiting.step1")}</li>
        <li>{t("agentBoard.waiting.step2")}</li>
        <li>{t("agentBoard.waiting.step3")}</li>
      </ol>
      <p className="ab-hint">
        {t("agentBoard.waiting.folder")} <code>{folder}</code>
      </p>
      <TurnOff store={store} strings={strings} />
    </section>
  );
}

function TurnOff({ store, strings }: Props) {
  const [error, setError] = useState<string>();
  return (
    <>
      <button
        type="button"
        className="ui-button ui-btn"
        data-variant="subtle"
        data-size="md"
        onClick={() => {
          setError(undefined);
          store
            .setEnabled(false)
            .catch((reason: unknown) => setError(failureMessage(reason) ?? strings.t("agentBoard.failed")));
        }}
      >
        {strings.t("agentBoard.turnOff")}
      </button>
      {error && (
        <span className="ab-error" role="alert">
          {error}
        </span>
      )}
    </>
  );
}

function Loading({ strings }: { strings: Strings }) {
  return (
    <div className="ab-board" aria-busy="true" aria-label={strings.t("agentBoard.loading")}>
      <div className="ab-agents">
        {[0, 1, 2, 3].map((i) => (
          <span key={i} className="ab-skeleton ab-skeleton-row" />
        ))}
      </div>
      <div className="ab-detail">
        <span className="ab-skeleton ab-skeleton-title" />
        <span className="ab-skeleton ab-skeleton-block" />
      </div>
    </div>
  );
}

// MARK: - The board

function needsYouCapabilities(board: Board): Set<string> {
  return new Set(
    board.capabilities
      .filter(
        (c) =>
          permutationsFor(board, c.id).some((p) => p.status !== "verified") ||
          board.decisions.some((d) => d.needsHuman && d.for?.includes(c.id)),
      )
      .map((c) => c.id),
  );
}

function BoardView({
  store,
  strings,
  agents,
  readAtMs,
  stale,
}: Props & { agents: AgentLedger[]; readAtMs: number; stale?: string }) {
  const { t } = strings;
  const [selected, setSelected] = useState(agents[0]?.file ?? "");
  const [needsYou, setNeedsYou] = useState(false);
  const active = agents.find((a) => a.file === selected) ?? agents[0];
  const all = coverage(agents.flatMap((a) => a.board.permutations));
  const capabilities = agents.reduce((n, a) => n + a.board.capabilities.length, 0);
  const human = agents.reduce((n, a) => n + a.board.decisions.filter((d) => d.needsHuman).length, 0);
  return (
    <div className="ab-page">
      <header className="ab-header">
        <h1>{t("agentBoard.title")}</h1>
        <dl className="ab-stats">
          <div>
            <dt>{t("agentBoard.stats.agents")}</dt>
            <dd>{agents.length}</dd>
          </div>
          <div>
            <dt>{t("agentBoard.stats.capabilities")}</dt>
            <dd>{capabilities}</dd>
          </div>
          <div>
            <dt>{t("agentBoard.stats.verified")}</dt>
            <dd>
              {all.verified}/{all.total}
            </dd>
          </div>
          <div>
            <dt>{t("agentBoard.stats.needsYou")}</dt>
            <dd className={human ? "ab-attention" : undefined}>{human}</dd>
          </div>
        </dl>
        <div className="ab-header-actions">
          <label className="ab-toggle">
            <input
              type="checkbox"
              aria-label={t("agentBoard.filter.needsYou")}
              checked={needsYou}
              onChange={(e) => setNeedsYou(e.target.checked)}
            />
            {t("agentBoard.filter.needsYou")}
          </label>
          <TurnOff store={store} strings={strings} />
        </div>
      </header>
      {stale && <output className="ab-note-line ab-block">{stale}</output>}
      <div className="ab-board">
        <AgentList
          agents={agents}
          now={readAtMs}
          selected={active?.file ?? ""}
          onSelect={setSelected}
          strings={strings}
        />
        {active && (
          <Detail
            key={`${active.file}:${needsYou}`}
            agent={active}
            store={store}
            strings={strings}
            needsYou={needsYou}
          />
        )}
      </div>
    </div>
  );
}

const LIVE_MS = 5 * 60_000;

function AgentList({
  agents,
  now,
  selected,
  onSelect,
  strings,
}: {
  agents: AgentLedger[];
  /** When the ledgers were read: ages and the live dot count from it, never from the first mount. */
  now: number;
  selected: string;
  onSelect(file: string): void;
  strings: Strings;
}) {
  const { t } = strings;
  const ago = new Intl.RelativeTimeFormat(strings.language, { numeric: "auto", style: "short" });
  const when = (ms: number) => {
    const minutes = Math.min(0, Math.round((ms - now) / 60_000));
    if (Math.abs(minutes) < 60) return ago.format(minutes, "minute");
    const hours = Math.round(minutes / 60);
    return Math.abs(hours) < 48 ? ago.format(hours, "hour") : ago.format(Math.round(hours / 24), "day");
  };
  return (
    <nav className="ab-agents" aria-label={t("agentBoard.stats.agents")}>
      {agents.map(({ file, modifiedMs, board }) => {
        const c = coverage(board.permutations);
        const human = board.decisions.filter((d) => d.needsHuman).length;
        const broken = c.broken + board.problems.length;
        const live = now - modifiedMs < LIVE_MS;
        const meta = [board.task?.agent, board.task?.workspace, when(modifiedMs)].filter(Boolean).join(" · ");
        return (
          <button
            type="button"
            key={file}
            className="ab-agent"
            aria-current={file === selected ? "true" : undefined}
            onClick={() => onSelect(file)}
          >
            <span
              className={`ab-dot${live ? " ab-dot-live" : ""}`}
              title={t(live ? "agentBoard.agent.recent" : "agentBoard.agent.quiet")}
            />
            <span className="ab-agent-text">
              <span className="ab-agent-name">{board.task?.title ?? file.replace(/\.jsonl$/, "")}</span>
              <span className="ab-agent-meta">{meta}</span>
            </span>
            <span className="ab-agent-counts">
              {human > 0 && (
                <span className="ab-flag" title={t("agentBoard.stats.needsYou")}>
                  {human}
                </span>
              )}
              {broken > 0 && (
                <span className="ab-count-bad" title={t("agentBoard.status.broken")}>
                  {broken}
                </span>
              )}
              <span className="ab-muted">
                {c.verified}/{c.total}
              </span>
            </span>
          </button>
        );
      })}
    </nav>
  );
}

function Detail({
  agent,
  store,
  strings,
  needsYou,
}: {
  agent: AgentLedger;
  store: AgentBoardStore;
  strings: Strings;
  needsYou: boolean;
}) {
  const { t } = strings;
  const { board } = agent;
  const [viewing, setViewing] = useState<EvidenceRecord | null>(null);
  const attention = needsYouCapabilities(board);
  const caps = needsYou ? board.capabilities.filter((c) => attention.has(c.id)) : board.capabilities;
  const decisions = needsYou ? board.decisions.filter((d) => d.needsHuman) : board.decisions;
  const human = board.decisions.filter((d) => d.needsHuman);
  const empty = board.capabilities.length === 0 && board.decisions.length === 0;
  return (
    <section className="ab-detail" aria-label={board.task?.title ?? agent.file}>
      <header className="ab-detail-head">
        <h2>{board.task?.title ?? agent.file}</h2>
        {board.task?.goal && <p className="ab-goal">{board.task.goal}</p>}
        <p className="ab-detail-links">
          {board.task?.branch && <code>{board.task.branch}</code>}
          {board.task?.pr && (
            <button type="button" className="ab-link" onClick={() => void store.open({ url: board.task?.pr })}>
              {t("agentBoard.pullRequest")}
            </button>
          )}
        </p>
      </header>
      {agent.truncated && <p className="ab-note-line">{t("agentBoard.truncated")}</p>}
      {board.problems.length > 0 && (
        <div className="ab-problems" role="alert">
          <strong>{t("agentBoard.problems.title")}</strong>
          <ul>
            {board.problems.map((p) => (
              <li key={p.line}>
                {p.reason === "json" || p.reason === "object"
                  ? strings.format(`agentBoard.problems.${p.reason}`, String(p.line))
                  : strings.format("agentBoard.problems.field", String(p.line), p.reason)}{" "}
                <code className="ab-break">{p.text}</code>
              </li>
            ))}
          </ul>
        </div>
      )}
      {empty && <p className="ab-muted">{t("agentBoard.nothingYet")}</p>}
      {human.length > 0 && (
        <div className="ab-banner">
          <strong>{t("agentBoard.banner.needsYou")}</strong> {human.map((d) => d.title).join(", ")}
        </div>
      )}
      {needsYou && caps.length === 0 && decisions.length === 0 && !empty && (
        <p className="ab-muted">{t("agentBoard.nothingNeedsYou")}</p>
      )}
      {caps.map((cap) => (
        <CapabilityGrid
          key={cap.id}
          cap={cap}
          board={board}
          store={store}
          strings={strings}
          onlyOpen={needsYou}
          onOpen={setViewing}
        />
      ))}
      {decisions.length > 0 && (
        <section className="ab-decisions" aria-labelledby={`ab-decisions-${agent.file}`}>
          <h3 className="ab-section" id={`ab-decisions-${agent.file}`}>
            {t("agentBoard.decisions")}
          </h3>
          <div className="ab-decision-grid">
            {decisions.map((d) => (
              <DecisionCard key={d.id} decision={d} strings={strings} />
            ))}
          </div>
        </section>
      )}
      <EvidenceViewer
        board={board}
        evidence={viewing}
        store={store}
        strings={strings}
        onClose={() => setViewing(null)}
      />
    </section>
  );
}

const STATUS_TONE = {
  verified: "ok",
  done: "ok",
  broken: "bad",
  dropped: "off",
  unverified: "wait",
  building: "wait",
} as const;

function StatusMark({ status, strings }: { status: keyof typeof STATUS_TONE; strings: Strings }) {
  return (
    <span className={`ab-status ab-status-${STATUS_TONE[status]}`}>
      <span className="ab-sr">{strings.t(`agentBoard.status.${status}`)}</span>
    </span>
  );
}

function CoverageBar({ permutations, strings }: { permutations: PermutationRecord[]; strings: Strings }) {
  const c = coverage(permutations);
  if (!c.total) return <span className="ab-muted ab-coverage">{strings.t("agentBoard.noStates")}</span>;
  return (
    <span className="ab-coverage">
      <span className="ab-coverage-track" aria-hidden="true">
        <span className="ab-coverage-ok" style={{ width: `${(c.verified / c.total) * 100}%` }} />
        <span className="ab-coverage-bad" style={{ width: `${(c.broken / c.total) * 100}%` }} />
      </span>
      <span>
        {c.verified}/{c.total} {strings.t("agentBoard.verified")}
      </span>
      {c.broken > 0 && (
        <span className="ab-count-bad" title={strings.t("agentBoard.status.broken")}>
          {c.broken}
        </span>
      )}
    </span>
  );
}

function evidenceFor(board: Board, p: PermutationRecord): EvidenceRecord[] {
  const linked = (p.evidence ?? []).flatMap((id) => {
    const e = board.evidence.get(id);
    return e ? [e] : [];
  });
  if (linked.length) return linked;
  return [...board.evidence.values()].filter((e) => e.for?.includes(p.id));
}

const IMAGE = /\.(png|jpe?g|gif|webp)$/i;

function CapabilityGrid({
  cap,
  board,
  store,
  strings,
  onlyOpen,
  onOpen,
}: {
  cap: CapabilityRecord;
  board: Board;
  store: AgentBoardStore;
  strings: Strings;
  onlyOpen: boolean;
  onOpen(e: EvidenceRecord): void;
}) {
  const { t } = strings;
  const all = permutationsFor(board, cap.id);
  const perms = onlyOpen ? all.filter((p) => p.status !== "verified") : all;
  return (
    <section className="ab-cap" aria-label={cap.title}>
      <header className="ab-cap-head">
        <StatusMark status={cap.status} strings={strings} />
        <h3>{cap.title}</h3>
        {cap.area && <span className="ab-tag">{cap.area}</span>}
        <CoverageBar permutations={all} strings={strings} />
      </header>
      {cap.summary && <p className="ab-summary">{cap.summary}</p>}
      <div className="ab-grid">
        {perms.map((p) => {
          const ev = evidenceFor(board, p);
          const shot = ev.find((e) => e.path && IMAGE.test(e.path));
          const first = shot ?? ev[0];
          return (
            <button
              type="button"
              key={p.id}
              className="ab-cell"
              data-status={p.status}
              aria-disabled={!first || undefined}
              onClick={() => first && onOpen(first)}
              aria-label={`${axesLabel(p.axes)}: ${t(`agentBoard.status.${p.status}`)}`}
            >
              <Thumb evidence={shot} fallback={first} permutation={p} store={store} strings={strings} />
              <span className="ab-cell-axes">
                {Object.entries(p.axes).map(([k, v]) => (
                  <span key={k} title={k}>
                    {v}
                  </span>
                ))}
              </span>
              <span className="ab-cell-foot">
                <StatusMark status={p.status} strings={strings} />
                {t(`agentBoard.status.${p.status}`)}
                {ev.length > 1 && <span className="ab-muted">+{ev.length - 1}</span>}
                {ev.some((e) => isStale(board, e)) && <span className="ab-stale">{t("agentBoard.stale")}</span>}
              </span>
              {p.note && <span className="ab-cell-note">{p.note}</span>}
            </button>
          );
        })}
        {perms.length === 0 && (
          <p className="ab-muted">{t(onlyOpen ? "agentBoard.allVerified" : "agentBoard.noStates")}</p>
        )}
      </div>
    </section>
  );
}

const TYPE_GLYPH: Record<EvidenceRecord["type"], string> = {
  screenshot: "▣",
  video: "▶",
  test: "✓",
  build: "⬢",
  log: "≡",
  link: "↗",
};

function useImage(store: AgentBoardStore, path?: string): EvidenceImage | "failed" | undefined {
  const [image, setImage] = useState<{ path: string; value: EvidenceImage | "failed" }>();
  useEffect(() => {
    if (!path) return;
    let live = true;
    store.image(path).then(
      (value) => live && setImage({ path, value }),
      () => live && setImage({ path, value: "failed" }),
    );
    return () => {
      live = false;
    };
  }, [store, path]);
  return image && image.path === path ? image.value : undefined;
}

function Thumb({
  evidence,
  fallback,
  permutation,
  store,
  strings,
}: {
  evidence?: EvidenceRecord;
  fallback?: EvidenceRecord;
  permutation: PermutationRecord;
  store: AgentBoardStore;
  strings: Strings;
}) {
  const image = useImage(store, evidence?.path);
  const phone = /iphone|ipad|ios/i.test(axesLabel(permutation.axes));
  const frame = `ab-thumb${phone ? " ab-thumb-phone" : ""}`;
  if (image && image !== "failed" && "dataURL" in image)
    return (
      <span className={frame}>
        <img src={image.dataURL} alt={evidence?.caption ?? ""} />
      </span>
    );
  if (fallback && (!evidence || image === "failed" || (image && "tooLarge" in image)))
    return (
      <span className={`${frame} ab-thumb-type`} aria-hidden="true">
        <span className="ab-thumb-glyph">{TYPE_GLYPH[fallback.type]}</span>
        <span className="ab-thumb-label">{strings.t(`agentBoard.evidence.${fallback.type}`)}</span>
      </span>
    );
  if (evidence && !image) return <span className={`${frame} ab-skeleton`} aria-hidden="true" />;
  return <span className={`${frame} ab-thumb-missing`} aria-hidden="true" />;
}

function DecisionCard({ decision, strings }: { decision: DecisionRecord; strings: Strings }) {
  const { t } = strings;
  return (
    <article className={`ab-decision${decision.needsHuman ? " ab-decision-human" : ""}`}>
      <header>
        <h4>{decision.title}</h4>
        {decision.needsHuman && <span className="ab-flag">{t("agentBoard.stats.needsYou")}</span>}
      </header>
      <p>
        <span className="ab-muted">{t("agentBoard.decision.chose")}</span> {decision.chosen}
      </p>
      {decision.why && <p className="ab-muted">{decision.why}</p>}
      {decision.rejected?.length ? (
        <ul className="ab-rejected" aria-label={t("agentBoard.decision.rejected")}>
          {decision.rejected.map((r, i) => (
            <li key={`${i}:${r.option}`}>
              <s>{r.option}</s>
              {r.why && <span className="ab-muted"> — {r.why}</span>}
            </li>
          ))}
        </ul>
      ) : null}
    </article>
  );
}

function EvidenceViewer({
  board,
  evidence,
  store,
  strings,
  onClose,
}: {
  board: Board;
  evidence: EvidenceRecord | null;
  store: AgentBoardStore;
  strings: Strings;
  onClose(): void;
}) {
  const { t } = strings;
  const [openError, setOpenError] = useState<string>();
  const imagePath = evidence?.path && IMAGE.test(evidence.path) ? evidence.path : undefined;
  const image = useImage(store, imagePath);
  const proves = evidence
    ? board.permutations.filter((p) => p.evidence?.includes(evidence.id) || evidence.for?.includes(p.id))
    : [];
  const target = evidence?.url ? { url: evidence.url } : evidence?.path ? { path: evidence.path } : undefined;
  return (
    <Dialog
      open={Boolean(evidence)}
      onOpenChange={(open) => {
        if (!open) {
          setOpenError(undefined);
          onClose();
        }
      }}
      className="ab-dialog ab-viewer"
    >
      {evidence && (
        <>
          <DialogTitle className="ab-dialog-title">
            {evidence.caption ?? t(`agentBoard.evidence.${evidence.type}`)}
          </DialogTitle>
          {imagePath && (
            <div className="ab-viewer-media">
              {image && image !== "failed" && "dataURL" in image ? (
                <img src={image.dataURL} alt={evidence.caption ?? ""} />
              ) : image === "failed" ? (
                <p className="ab-muted">{t("agentBoard.viewer.imageFailed")}</p>
              ) : image && "tooLarge" in image ? (
                <p className="ab-muted">{t("agentBoard.viewer.tooLarge")}</p>
              ) : (
                <span className="ab-skeleton ab-skeleton-image" />
              )}
            </div>
          )}
          <dl className="ab-viewer-meta">
            <dt>{t("agentBoard.viewer.type")}</dt>
            <dd>{t(`agentBoard.evidence.${evidence.type}`)}</dd>
            <dt>{t("agentBoard.viewer.commit")}</dt>
            <dd>
              <code>{evidence.sha ?? "—"}</code>
              {isStale(board, evidence) && <span className="ab-stale">{t("agentBoard.viewer.stale")}</span>}
            </dd>
            <dt>{evidence.url ? t("agentBoard.viewer.link") : t("agentBoard.viewer.file")}</dt>
            <dd>
              <code className="ab-break">{evidence.url ?? evidence.path}</code>
            </dd>
            {proves.length > 0 && (
              <>
                <dt>{t("agentBoard.viewer.proves")}</dt>
                <dd>{proves.map((p) => axesLabel(p.axes)).join(", ")}</dd>
              </>
            )}
          </dl>
          {openError && (
            <p className="ab-error" role="alert">
              {openError}
            </p>
          )}
          <div className="ab-dialog-actions">
            {target && (
              <DialogButton
                dialogKey={{ command: "o" }}
                className="ui-button ui-btn"
                data-variant="subtle"
                data-size="md"
                onClick={() =>
                  store
                    .open(target)
                    .catch((reason: unknown) => setOpenError(failureMessage(reason) ?? t("agentBoard.failed")))
                }
              >
                {t("agentBoard.viewer.open")}
              </DialogButton>
            )}
            <DialogButton
              dialogKey="escape"
              className="ui-button ui-btn"
              data-variant="solid"
              data-size="md"
              onClick={onClose}
            >
              {t("agentBoard.viewer.close")}
            </DialogButton>
          </div>
        </>
      )}
    </Dialog>
  );
}
