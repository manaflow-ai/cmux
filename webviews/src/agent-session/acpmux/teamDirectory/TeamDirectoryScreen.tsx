// People (History > People, behind the `team-directory` experiment): RFD 0170 phase 1 in the pane.
// The team navigator (the viewer's teams, the current team's spaces with unread and open counts and
// who is live in each, and one search across people, agents, threads, RFDs and sessions), the
// recipient picker (Send to) and a session's links (Session Info's threads, RFDs and participants).
// Every answer is acpmux's (`_acpmux/team/navigator`, `_acpmux/team/pick`, `_acpmux/team/session_info`,
// built and permission-filtered in Rust by cmux-team-messaging); this page draws it in the order it
// came and keeps no logic of its own beyond which read to ask for.
import { useEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Tooltip } from "../../../ui/Tooltip";
import { useT, type StringKey } from "../i18n";
import {
  directoryReason,
  readNavigator,
  readPicked,
  readSessionInfo,
  type Candidate,
  type DirectoryReason,
  type DirectoryResult,
  type Hit,
  type LiveRow,
  type PresenceStatus,
  type Navigator,
  type ParticipantRow,
  type Picked,
  type RefKey,
  type SessionInfoAnswer,
  type SpaceRow,
} from "./teamDirectoryModel";
import "./teamDirectory.css";

export type DirectoryMethod = "navigator" | "pick" | "session_info";
/// One `_acpmux/team/<method>` read (direct.ts `teamDirectory`).
export type DirectoryLoad = (method: DirectoryMethod, params: Record<string, unknown>) => Promise<unknown>;

type Props = {
  load: DirectoryLoad;
  /// Opens chat `sessionId` (App.tsx `selectSession`). Unset: no Open chat.
  openSession?(sessionId: string): void;
  /// Opens a thread, RFD or space ref. Unset: those rows are text.
  openRef?(key: RefKey): void;
  /// Copies text, false when it did not take (conversation/clipboard.ts). Unset: no Copy link.
  copy?(text: string): Promise<boolean>;
  initialQuery?: string;
  initialPickQuery?: string;
  /// A session's links start open (the gallery).
  initialSessionId?: string;
};

const REASON_KEY: Record<DirectoryReason, StringKey> = {
  off: "teamDirectory.reason.off",
  notReady: "teamDirectory.reason.notReady",
  unknownViewer: "teamDirectory.reason.unknownViewer",
  notVisible: "teamDirectory.reason.notVisible",
  older: "teamDirectory.reason.older",
  failed: "teamDirectory.reason.failed",
};
const KIND_KEY: Record<string, StringKey> = {
  person: "teamDirectory.kind.person",
  agent: "teamDirectory.kind.agent",
  pairSpace: "teamDirectory.kind.pairSpace",
  team: "teamDirectory.kind.team",
  space: "teamDirectory.kind.space",
  thread: "teamDirectory.kind.thread",
  rfd: "teamDirectory.kind.rfd",
  session: "teamDirectory.kind.session",
};
const MODE_KEY: Record<string, StringKey> = {
  fyi: "teamDirectory.mode.fyi",
  ask: "teamDirectory.mode.ask",
  wake: "teamDirectory.mode.wake",
};

/// The answer to `params` (undefined: none asked). While the next read runs the last answer stays,
/// so the list keeps its place instead of blinking empty.
function useDirectoryRead<T>(
  load: DirectoryLoad,
  method: DirectoryMethod,
  params: Record<string, unknown> | undefined,
  read: (value: unknown) => T | undefined,
): { result?: DirectoryResult<T>; loading: boolean } {
  const key = params ? JSON.stringify(params) : undefined;
  const [state, setState] = useState<{ key?: string; result?: DirectoryResult<T> }>({});
  const loadRef = useRef(load);
  const readRef = useRef(read);
  useEffect(() => {
    loadRef.current = load;
    readRef.current = read;
  });
  useEffect(() => {
    if (!key) return;
    let live = true;
    loadRef.current(method, JSON.parse(key) as Record<string, unknown>).then(
      (value) => {
        if (!live) return;
        const answer = readRef.current(value);
        setState({
          key,
          result: answer ? { kind: "ready", value: answer } : { kind: "none", reason: "failed" },
        });
      },
      (error: unknown) => {
        if (live) setState({ key, result: { kind: "none", reason: directoryReason(error) } });
      },
    );
    return () => {
      live = false;
    };
  }, [key, method]);
  return { ...(state.result ? { result: state.result } : {}), loading: key !== undefined && state.key !== key };
}

function Presence({ row }: { row: { status?: PresenceStatus | null; working: boolean } }) {
  const t = useT();
  return (
    <span
      className="tdir-dot"
      data-status={row.status ?? "none"}
      data-working={row.working ? "" : undefined}
      {...(row.working ? { "aria-label": t("teamDirectory.working"), role: "img" } : {})}
    />
  );
}

function LiveChips({ rows }: { rows: LiveRow[] }) {
  return (
    <>
      {rows.map((row) => (
        <li key={row.principalId} className="tdir-chip">
          <Presence row={row} />
          <span className="tdir-chip-name">{row.name}</span>
        </li>
      ))}
    </>
  );
}

function SpaceItem({ space }: { space: SpaceRow }) {
  const t = useT();
  const shown = space.people.length + space.agents.length;
  // The rows are a preview; the totals say how many more are live (unset: the rows are all of them).
  const live = (space.peopleLive ?? space.people.length) + (space.agentsLive ?? space.agents.length);
  const more = live - shown;
  return (
    <li className="tdir-space" data-kind={space.kind}>
      <div className="tdir-space-head">
        <span className="tdir-space-title">{space.title}</span>
        {space.unread > 0 && (
          <Tooltip label={t("teamDirectory.unread")}>
            <span className="tdir-count" data-tone="unread">
              {space.unread}
            </span>
          </Tooltip>
        )}
        {space.open > 0 && (
          <Tooltip label={t("teamDirectory.open")}>
            <span className="tdir-count">{space.open}</span>
          </Tooltip>
        )}
      </div>
      {live > 0 ? (
        <ul className="tdir-chips">
          <LiveChips rows={space.people} />
          <LiveChips rows={space.agents} />
          {more > 0 && <li className="tdir-chip tdir-more">{t("teamDirectory.more", { count: more })}</li>}
        </ul>
      ) : (
        <p className="tdir-quiet">{t("teamDirectory.noOneHere")}</p>
      )}
    </li>
  );
}

function HitItem({ hit, onSession, openRef }: { hit: Hit; onSession(id: string): void; openRef?: Props["openRef"] }) {
  const t = useT();
  const kind = KIND_KEY[hit.kind];
  const session = hit.kind === "session" ? hit.open?.id : undefined;
  const open = session ? () => onSession(session) : hit.open && openRef ? () => openRef(hit.open!) : undefined;
  const body = (
    <>
      <span className="tdir-row-label">{hit.label}</span>
      {hit.detail && <span className="tdir-row-detail">{hit.detail}</span>}
      {kind && <span className="tdir-tag">{t(kind)}</span>}
    </>
  );
  return (
    <li className="tdir-row" data-kind={hit.kind}>
      {open ? (
        <Button bare className="tdir-row-button" onClick={open}>
          {body}
        </Button>
      ) : (
        <div className="tdir-row-button">{body}</div>
      )}
    </li>
  );
}

function CandidateItem({ candidate }: { candidate: Candidate }) {
  const t = useT();
  const kind = KIND_KEY[candidate.kind];
  const mode = MODE_KEY[candidate.mode];
  return (
    <li className="tdir-row" data-kind={candidate.kind}>
      <div className="tdir-row-button">
        {candidate.status !== undefined && <Presence row={{ status: candidate.status, working: candidate.working }} />}
        <span className="tdir-row-label">{candidate.label}</span>
        {candidate.handle && <span className="tdir-row-detail">@{candidate.handle}</span>}
        {candidate.owner && <span className="tdir-row-detail">{candidate.owner}</span>}
        {kind && <span className="tdir-tag">{t(kind)}</span>}
        {mode && (
          <span className="tdir-tag" data-mode={candidate.mode}>
            {t(mode)}
          </span>
        )}
      </div>
    </li>
  );
}

function Participants({ title, rows }: { title: StringKey; rows: ParticipantRow[] }) {
  const t = useT();
  if (rows.length === 0) return null;
  return (
    <section className="tdir-section">
      <h3 className="tdir-heading">{t(title)}</h3>
      <ul className="tdir-chips">
        {rows.map((row) => (
          <li key={row.principalId} className="tdir-chip" data-standing={row.standing}>
            <Presence row={{ status: row.status ?? null, working: row.working }} />
            <span className="tdir-chip-name">{row.name}</span>
            {row.harness && <span className="tdir-row-detail">{row.harness}</span>}
          </li>
        ))}
      </ul>
    </section>
  );
}

function SessionLinks({
  info,
  openSession,
  openRef,
  copy,
  onClose,
}: {
  info: SessionInfoAnswer;
  openSession?: Props["openSession"];
  openRef?: Props["openRef"];
  copy?: Props["copy"];
  onClose(): void;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const link = info.actions.find((a) => a.action === "copyLink");
  const linkText = link?.action === "copyLink" ? link.link : undefined;
  const refButton = (key: RefKey, label: string, detail?: string) => (
    <li key={`${key.kind}/${key.source}/${key.id}`} className="tdir-row">
      {openRef ? (
        <Button bare className="tdir-row-button" onClick={() => openRef(key)}>
          <span className="tdir-row-label">{label}</span>
          {detail && <span className="tdir-row-detail">{detail}</span>}
        </Button>
      ) : (
        <div className="tdir-row-button">
          <span className="tdir-row-label">{label}</span>
          {detail && <span className="tdir-row-detail">{detail}</span>}
        </div>
      )}
    </li>
  );
  return (
    <article className="tdir-card tdir-session" aria-label={t("teamDirectory.session.title")}>
      <header className="tdir-card-head">
        <h2 className="tdir-heading">{t("teamDirectory.session.title")}</h2>
        <span className="tdir-row-detail">{info.spaceTitle ?? info.teamName}</span>
        <span className="tdir-fill" />
        {openSession && (
          <Button size="sm" variant="ghost" onClick={() => openSession(info.session.id)}>
            {t("teamDirectory.session.openChat")}
          </Button>
        )}
        {copy && linkText && (
          <Button size="sm" variant="ghost" onClick={() => void copy(linkText).then(setCopied)}>
            {copied ? t("teamDirectory.session.copied") : t("teamDirectory.session.copyLink")}
          </Button>
        )}
        <Button size="sm" variant="ghost" onClick={onClose}>
          {t("teamDirectory.session.close")}
        </Button>
      </header>
      {info.currentAsk && (
        <p className="tdir-ask">
          <span className="tdir-tag">{t("teamDirectory.session.asking")}</span> {info.currentAsk.excerpt}
        </p>
      )}
      {info.threads.length === 0 && info.rfds.length === 0 ? (
        <p className="tdir-quiet">{t("teamDirectory.session.nothingLinked")}</p>
      ) : (
        <>
          {info.threads.length > 0 && (
            <section className="tdir-section">
              <h3 className="tdir-heading">{t("teamDirectory.session.threads")}</h3>
              <ul className="tdir-rows">{info.threads.map((th) => refButton(th.key, th.subject, th.spaceTitle))}</ul>
            </section>
          )}
          {info.rfds.length > 0 && (
            <section className="tdir-section">
              <h3 className="tdir-heading">{t("teamDirectory.session.rfds")}</h3>
              <ul className="tdir-rows">{info.rfds.map((r) => refButton(r.key, r.label, r.title))}</ul>
            </section>
          )}
        </>
      )}
      <Participants title="teamDirectory.session.people" rows={info.people} />
      <Participants title="teamDirectory.session.agents" rows={info.agents} />
    </article>
  );
}

function Status({ reason }: { reason: DirectoryReason }) {
  const t = useT();
  return (
    <p className="tdir-status" data-reason={reason}>
      {t(REASON_KEY[reason])}
    </p>
  );
}

export function TeamDirectoryScreen({
  load,
  openSession,
  openRef,
  copy,
  initialQuery = "",
  initialPickQuery = "",
  initialSessionId,
}: Props) {
  const t = useT();
  const [query, setQuery] = useState(initialQuery);
  const [pickQuery, setPickQuery] = useState(initialPickQuery);
  const [teamId, setTeamId] = useState<string | undefined>(undefined);
  const [sessionId, setSessionId] = useState<string | undefined>(initialSessionId);
  const teamParam = teamId ? { teamId } : {};
  const nav = useDirectoryRead<Navigator>(load, "navigator", { query, ...teamParam }, readNavigator);
  const pick = useDirectoryRead<Picked>(load, "pick", { query: pickQuery, ...teamParam }, readPicked);
  const session = useDirectoryRead<SessionInfoAnswer>(
    load,
    "session_info",
    sessionId ? { sessionId } : undefined,
    readSessionInfo,
  );
  const navigator = nav.result?.kind === "ready" ? nav.result.value : undefined;
  const picked = pick.result?.kind === "ready" ? pick.result.value : undefined;
  const searching = query.trim() !== "";
  return (
    <div className="tdir" data-loading={nav.loading ? "" : undefined}>
      <div className="tdir-controls">
        <Input
          className="tdir-search"
          type="search"
          value={query}
          placeholder={t("teamDirectory.search")}
          aria-label={t("teamDirectory.search")}
          onChange={(event) => setQuery(event.currentTarget.value)}
        />
      </div>
      {nav.result?.kind === "none" ? (
        <Status reason={nav.result.reason} />
      ) : (
        <div className="tdir-body">
          <div className="tdir-main">
            {navigator && navigator.teams.length > 1 && (
              <ul className="tdir-teams" aria-label={t("teamDirectory.teams")}>
                {navigator.teams.map((team) => (
                  <li key={team.id}>
                    <Button
                      bare
                      className="tdir-team"
                      aria-current={team.current ? "true" : undefined}
                      onClick={() => setTeamId(team.id)}
                    >
                      {team.name}
                      {team.unread > 0 && (
                        <Tooltip label={t("teamDirectory.unread")}>
                          <span className="tdir-count" data-tone="unread">
                            {team.unread}
                          </span>
                        </Tooltip>
                      )}
                    </Button>
                  </li>
                ))}
              </ul>
            )}
            {searching ? (
              navigator && navigator.hits.length === 0 ? (
                <p className="tdir-quiet">{t("teamDirectory.noHits")}</p>
              ) : (
                <ul className="tdir-rows">
                  {navigator?.hits.map((hit) => (
                    <HitItem
                      key={`${hit.kind}/${hit.id}`}
                      hit={hit}
                      onSession={setSessionId}
                      {...(openRef ? { openRef } : {})}
                    />
                  ))}
                </ul>
              )
            ) : (
              <section className="tdir-section">
                <h2 className="tdir-heading">{t("teamDirectory.spaces")}</h2>
                {navigator && navigator.spaces.length === 0 ? (
                  <p className="tdir-quiet">{t("teamDirectory.noSpaces")}</p>
                ) : (
                  <ul className="tdir-spaces">
                    {navigator?.spaces.map((space) => (
                      <SpaceItem key={space.id} space={space} />
                    ))}
                  </ul>
                )}
              </section>
            )}
          </div>
          <div className="tdir-side">
            {sessionId &&
              (session.result?.kind === "ready" ? (
                <SessionLinks
                  info={session.result.value}
                  onClose={() => setSessionId(undefined)}
                  {...(openSession ? { openSession } : {})}
                  {...(openRef ? { openRef } : {})}
                  {...(copy ? { copy } : {})}
                />
              ) : session.result?.kind === "none" ? (
                <Status reason={session.result.reason} />
              ) : null)}
            <section className="tdir-card tdir-pick">
              <h2 className="tdir-heading">{t("teamDirectory.pick.title")}</h2>
              <Input
                size="sm"
                value={pickQuery}
                placeholder={t("teamDirectory.pick.placeholder")}
                aria-label={t("teamDirectory.pick.title")}
                onChange={(event) => setPickQuery(event.currentTarget.value)}
              />
              {pick.result?.kind === "none" ? (
                <Status reason={pick.result.reason} />
              ) : picked && picked.resolved.length > 1 ? (
                <p className="tdir-quiet">{t("teamDirectory.pick.ambiguous")}</p>
              ) : picked && picked.candidates.length === 0 ? (
                <p className="tdir-quiet">{t("teamDirectory.pick.none")}</p>
              ) : null}
              <ul className="tdir-rows">
                {picked?.candidates.map((candidate) => (
                  <CandidateItem key={`${candidate.kind}/${candidate.id}`} candidate={candidate} />
                ))}
              </ul>
            </section>
          </div>
        </div>
      )}
    </div>
  );
}
