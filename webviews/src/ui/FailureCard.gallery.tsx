// l10n-allow-file: gallery fixtures (sample chat names, errors, labels), not shipped UI.
// One failure card (Beyer P1 one of each thing, P4 name the specific thing), for the four things that
// stop: a turn, a host or connection, a sign-in, a New Tab start. Today those are a card plus button
// (turn, sign-in), a sentence plus a pill (host) and underlined text links (New Tab): `now-*` draws
// each as shipped. The rest are the one shape, ui/FailureCard.tsx:
//   a-*: an inline row, no card, a quiet fill, title and cause on one line, the fix at the end;
//   b-*: a card, the cause on its own line, one primary fix and nothing else;
//   c-*: a card whose cause waits behind "Show log", with the primary fix and that quiet secondary.
import { componentEntry } from "../gallery/format";
import type { ComponentVariant } from "../gallery/format";
import type { Play } from "../gallery/play";
import { TurnFooter } from "../agent-session/acpmux/conversation/TurnRows";
import { TurnActionsContext } from "../agent-session/acpmux/conversation/turnActions";
import { HarnessHealthNotice } from "../agent-session/acpmux/HarnessHealthNotice";
import { HostError } from "../agent-session/acpmux/HostError";
import { NoticeSlot } from "../agent-session/acpmux/NoticeSlot";
import { StartFailure } from "../agent-session/acpmux/newtab/StartFailure";
import { FailureCard, type FailureCardLayout } from "./FailureCard";

type Kind = "turn" | "host" | "signin" | "start";
type Props = { kind: Kind; layout: FailureCardLayout | "now" };

const noop = () => undefined;

/// A failed turn whose agent process quit, as acpmux records its summary row.
const FAILED_TURN = {
  id: "summary-2",
  version: 1,
  at: Date.UTC(2026, 10, 22, 3, 12),
  kind: "turnSummary" as const,
  seq: 2,
  status: "failed" as const,
  durationMs: 41_000,
  error: "claude-agent-acp exited with code 137",
  prompt: "Fix the login bug",
  retryRowId: "user-1",
};

const COPY: Record<Kind, { title: string; cause: string; fix: string; log: string }> = {
  turn: {
    title: "Claude Code stopped in “Fix the login bug”",
    cause: "Exited with code 137: the process was killed, out of memory",
    fix: "Retry",
    log: "Show log",
  },
  host: {
    title: "“Fix the login bug” can’t be reached on build-box",
    cause: "No route to host: build-box last answered 4 minutes ago",
    fix: "Reconnect",
    log: "Show log",
  },
  signin: {
    title: "Claude Code is signed out",
    cause: "The saved login expired: 401 Unauthorized from the API",
    fix: "Sign in",
    log: "Show log",
  },
  start: {
    title: "Claude Code isn’t installed on this Mac",
    cause: "spawn claude-agent-acp ENOENT",
    fix: "Install Claude Code",
    log: "Show log",
  },
};

function Now({ kind }: { kind: Kind }) {
  if (kind === "start")
    return (
      <StartFailure
        failure={{ harness: "claude", error: "spawn claude-agent-acp ENOENT", local: true, retry: noop }}
        name="Claude Code"
        onInstall={noop}
        onDismiss={noop}
      />
    );
  if (kind === "host") return <HostError message="Update cmux to open this chat, then Retry." onRetry={noop} />;
  if (kind === "signin")
    return (
      <NoticeSlot>
        <HarnessHealthNotice
          health={{ id: "claude", auth: "signedOut", login: "claude /login" }}
          harness="claude"
          name="Claude Code"
          open={noop}
          native={() => Promise.resolve({})}
        />
      </NoticeSlot>
    );
  // The real turn footer (TurnRows.tsx TurnFooter) over a failed turn whose agent quit (agent-exited).
  return (
    <TurnActionsContext.Provider value={{ retry: noop }}>
      <TurnFooter row={FAILED_TURN as never} />
    </TurnActionsContext.Provider>
  );
}

function FailureGallery({ kind, layout }: Props) {
  if (layout === "now")
    return (
      <div className="ui-failure-gallery" data-gallery-capture="">
        <Now kind={kind} />
      </div>
    );
  const copy = COPY[kind];
  return (
    <div className="ui-failure-gallery" data-gallery-capture="">
      <FailureCard
        layout={layout}
        title={copy.title}
        cause={copy.cause}
        primary={{ label: copy.fix, onSelect: noop }}
        {...(layout === "card"
          ? {}
          : { secondary: { label: copy.log, onSelect: noop }, secondaryOpenLabel: "Hide log" })}
      />
    </div>
  );
}

const LAYOUTS: [string, FailureCardLayout | "now", string][] = [
  ["now", "now", "Today, as shipped."],
  ["a", "row", "Inline row: no card, a quiet fill, cause trailing the title."],
  ["b", "card", "Card: the cause on its own line, one primary fix."],
  ["c", "disclosed", "Card: cause behind Show log, primary fix plus the quiet secondary."],
];
const KINDS: Kind[] = ["turn", "host", "signin", "start"];

const variants: Record<string, ComponentVariant<Props>> = {};
for (const [id, layout, note] of LAYOUTS)
  for (const kind of KINDS) variants[`${id}-${kind}`] = { props: { kind, layout }, note: `${note} (${kind})` };

const showLog: Play = async (ctx) => {
  await ctx.click({ text: "Show log" });
};
variants["c-turn-open"] = {
  props: { kind: "turn", layout: "disclosed" },
  note: "Disclosed: Show log opened.",
  play: showLog,
};

export default componentEntry<Props>({
  id: "ui.failure-card",
  title: "Failure card",
  area: "UI primitives",
  pane: true,
  height: 160,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: ["ui/FailureCard.tsx"],
  keywords: ["error", "failure", "repair", "sign in", "install", "reconnect", "retry", "notice"],
  load: async () => FailureGallery,
  styles: () =>
    Promise.all([
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/conversation/conversation.css"),
      import("./ui.css"),
    ]),
  variants,
});
