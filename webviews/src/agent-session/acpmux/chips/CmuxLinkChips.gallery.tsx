// l10n-allow-file: deterministic, public-safe gallery fixtures (sample prompts, titles, links).
// A pasted cmux link drawn as what it names (Leo, 2026-11-08: "when I paste the URL link, when I
// do the right-click copy link to workspace thing, it should be able to render in the box that it
// is an actual chat that is there, like with the title and whatever, and, like, to be potentially
// hoverable as well, instead of just being, like, you know, here's the raw URL"). Each variant is
// one look (chips/cmuxLinkLook.experiment.ts) of the same sent message: a local workspace link, a
// chat on another machine (an agent link), a cmux.com agent link, and a workspace id nothing names,
// which stays the link. Point at a chip for its card.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSessionEntry } from "../sessionList";
import { SessionHoverStore } from "../started/sessionHover";
import { SessionHoverContext } from "../started/sessionHoverCardModel";
import { PromptTyped } from "../conversation/PromptText";
import { setLinkPlaces } from "./cmuxLinkPlaces";
import { CmuxLinkChip } from "./CmuxLinkChip";
import { cmuxLinkLook, type CmuxLinkLook } from "./cmuxLinkLook.experiment";

const WORKSPACE = "cmux-nightly://workspace/ws_16c92e4354fcaf05540386720d78e251";
const TAB = "cmux-nightly://tab/tab_0123456789abcdef0123456789abcdef";
const AGENT = "cmux://agent/claude/9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
const WEB_AGENT = "https://cmux.com/deeplink/agent?harness=codex&session=0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d";
const GONE = "cmux-nightly://workspace/ws_00000000000000000000000000000000";
/// A workspace no push names when the message draws: the host's push names it after mount.
const LATE_ID = "ws_a1b2c3d4e5f60718293a4b5c6d7e8f90";
const LATE = `cmux-nightly://workspace/${LATE_ID}`;

const PLACES = [
  { id: "ws_16c92e4354fcaf05540386720d78e251", kind: "workspace", title: "Notice rows from acpmux" },
  {
    id: "tab_0123456789abcdef0123456789abcdef",
    kind: "tab",
    title: "Review the retry fix",
    workspace: "cmux next",
  },
];
setLinkPlaces(PLACES);

const store = new SessionHoverStore();
store.set([
  {
    sessionId: "gallery-reviewer",
    harness: "claude",
    agentSessionId: "9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f",
    title: "Review the retry fix",
    host: "build-box",
    hostKind: "cloud",
    cwd: "/Users/you/src/cmux",
  } as AcpmuxSessionEntry,
  {
    sessionId: "gallery-codex",
    harness: "codex",
    agentSessionId: "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d",
    title: "Profile the sidebar",
    hostKind: "local",
    cwd: "/Users/you/src/cmux",
  } as AcpmuxSessionEntry,
]);

const PROMPT = `In this chat, I feel like there was something weird here. ${WORKSPACE} Compare it with ${AGENT} and ${WEB_AGENT}; the old one ${GONE} is closed.`;

type Props = { look: CmuxLinkLook; late?: boolean };

/// The late link's chip title, or undefined while it is the link.
const lateTitle = (doc: Document) =>
  doc.querySelector(`[data-cmux-link-late] a[href="${LATE}"][data-cmux-link] .cv-cmux-link__title`)?.textContent ??
  undefined;

/// The host's pushes after the message drew, as the app's arrive (async, after mount): the late
/// workspace is named, renamed, closed and named again, and the sent chip follows each push (review
/// of #38166: the React Compiler had kept the chip's first answer, so it stayed the link).
async function pushAfterMount(ctx: PlayContext) {
  const doc = ctx.document;
  await ctx.waitFor(() => doc.querySelector(`[data-cmux-link-late] a[href="${LATE}"]`));
  if (lateTitle(doc) !== undefined) throw new Error("the late link drew as a chip before any push named it");
  const push = (title?: string) =>
    setLinkPlaces(title ? [...PLACES, { id: LATE_ID, kind: "workspace", title, host: "build-box" }] : PLACES);
  push("Retry fix");
  await ctx.waitFor(() => lateTitle(doc) === "Retry fix");
  push("Retry fix, take two");
  await ctx.waitFor(() => lateTitle(doc) === "Retry fix, take two");
  push();
  await ctx.waitFor(() => !doc.querySelector(`[data-cmux-link-late] a[href="${LATE}"][data-cmux-link]`));
  push("Retry fix, take two");
  await ctx.waitFor(() => lateTitle(doc) === "Retry fix, take two");
}

/// The prompt with every cmux link drawn in `look` (the sent message's own renderer, with the arm fixed).
function Gallery({ look, late }: Props) {
  // The sent message reads its look from the experiment; each variant fixes the arm.
  const scope = globalThis as { cmuxExperiments?: Record<string, string> };
  scope.cmuxExperiments = { ...scope.cmuxExperiments, [cmuxLinkLook.id]: look };
  return (
    <SessionHoverContext.Provider value={{ store, open: () => undefined }}>
      <main className="cv-md" data-cmux-link-gallery style={{ padding: 16, maxWidth: 640 }}>
        <div className="acpmux-user-bubble" data-cmux-link-look={look}>
          <PromptTyped text={PROMPT} show={(text) => text} />
        </div>
        <p>
          A tab: <CmuxLinkChip href={TAB} look={look} fallback={<a href={TAB}>{TAB}</a>} />
        </p>
        {late && (
          <div className="acpmux-user-bubble" data-cmux-link-late>
            <PromptTyped text={`Sent before the app named it: ${LATE}`} show={(text) => text} />
          </div>
        )}
      </main>
    </SessionHoverContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.cmux-link-chips",
  title: "Pasted cmux links",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-cmux-link-gallery]" }],
  covers: [
    "agent-session/acpmux/chips/CmuxLinkChip.tsx",
    "agent-session/acpmux/chips/cmuxLinkResolve.ts",
    "agent-session/acpmux/conversation/cmuxLinks.ts",
  ],
  keywords: ["deeplink", "workspace link", "chat link", "cmux://", "copy link to workspace"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../started/startedSessions.css"),
      import("./cmuxLinkChip.css"),
    ]),
  load: async () => Gallery,
  variants: {
    "icon-title-host": {
      props: { look: "icon-title-host" },
      note: "Picked. The session chip's wash, the kind's icon and the title; a chat or workspace on another machine adds the machine, muted. The closed workspace stays the link.",
    },
    "icon-title": {
      props: { look: "icon-title" },
      note: "Compared: the icon and title only. Shortest, but two chats of the same name on two machines read the same.",
    },
    "kind-title": {
      props: { look: "kind-title" },
      note: "Compared: the kind as a muted word before the title. Says what it is in words, but the word costs as much width as a short title.",
    },
    "pushed-after-mount": {
      props: { look: "icon-title-host", late: true },
      note: "A message sent before the app named its workspace: the host's push after it drew turns the link into its chip, a rename retitles it, a close puts the link back and the next push names it again.",
      play: pushAfterMount,
    },
    link: {
      props: { look: "link" },
      note: "Before: every link as written (Leo's screenshot: the raw link wrapping across lines).",
    },
  },
});
