// l10n-allow-file: deterministic, public-safe gallery fixtures (sample prompts, titles, links).
// A pasted cmux link drawn as what it names (Leo, 2026-11-08: "when I paste the URL link, when I
// do the right-click copy link to workspace thing, it should be able to render in the box that it
// is an actual chat that is there, like with the title and whatever, and, like, to be potentially
// hoverable as well, instead of just being, like, you know, here's the raw URL"). Each variant is
// one look (chips/cmuxLinkLook.experiment.ts) of the same sent message: a local workspace link, a
// chat on another machine (an agent link), a cmux.com agent link, and a workspace id nothing names,
// which stays the link. Point at a chip for its card. Two states from the review of #38166: a
// peer's chat that only acpmux's resolve names, with its link card open, and Markdown links
// (`[label](cmux://…)`) drawn as chips that keep the author's label.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSessionEntry } from "../sessionList";
import { SessionHoverStore } from "../started/sessionHover";
import { SessionHoverContext } from "../started/sessionHoverCardModel";
import { PromptTyped } from "../conversation/PromptText";
import { renderInline } from "../conversation/inlineMarkdown";
import { setSessionRefResolver } from "../conversation/sessionRefs";
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

/// A peer's chat the page does not list: acpmux's resolve names it (`_acpmux/resolve`).
const PEER_AGENT = "cmux://agent/codex/4e8a2d6c-1b3f-4a5e-9c7d-0f1e2d3c4b5a?host=build-box&name=peer";
setSessionRefResolver(async (query) =>
  query === PEER_AGENT ? { session: { sessionId: "gallery-peer", name: "Peer review", host: "build-box" } } : null,
);

const MARKDOWN = `Pick up [the notice rows](${WORKSPACE}), ask [the reviewer](${AGENT}), and skip [the old one](${GONE}).`;

const PROMPT = `In this chat, I feel like there was something weird here. ${WORKSPACE} Compare it with ${AGENT} and ${WEB_AGENT}; the old one ${GONE} is closed.`;

type Props = { look: CmuxLinkLook; late?: boolean; peer?: boolean; markdown?: boolean };

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

/// The peer's chip, once acpmux's resolve named it, focused: its link card opens.
async function openPeerCard(ctx: PlayContext) {
  const chip = "[data-cmux-link-peer] a[data-cmux-link=chat]";
  await ctx.waitFor(() => ctx.document.querySelector(chip), { capMs: 8000 });
  await ctx.focus({ selector: chip });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-cmux-link-card"));
}

/// The Markdown links' chips, drawn with their labels.
async function markdownChips(ctx: PlayContext) {
  await ctx.waitFor(
    () => ctx.document.querySelectorAll("[data-cmux-link-markdown] a[data-cmux-link-label]").length === 2,
  );
}

/// The prompt with every cmux link drawn in `look` (the sent message's own renderer, with the arm fixed).
function Gallery({ look, late, peer, markdown }: Props) {
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
        {peer && (
          <p data-cmux-link-peer>
            A peer&apos;s chat:{" "}
            <CmuxLinkChip href={PEER_AGENT} look={look} fallback={<a href={PEER_AGENT}>{PEER_AGENT}</a>} />
          </p>
        )}
        {markdown && <p data-cmux-link-markdown>{renderInline(MARKDOWN)}</p>}
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
    "peer-chat-card": {
      props: { look: "icon-title-host", peer: true },
      note: "A peer's chat the list does not have, named by acpmux's resolve: focused, it shows the link card (the chat's name, \"Chat on <machine>\", the link), as a workspace's chip does.",
      play: openPeerCard,
    },
    "markdown-links": {
      props: { look: "icon-title-host", markdown: true },
      note: "A reply's Markdown links to a workspace and a chat draw as their chips with the author's label in the title's place (the card still names the title); the closed workspace's link stays its labelled link.",
      play: markdownChips,
    },
    link: {
      props: { look: "link" },
      note: "Before: every link as written (Leo's screenshot: the raw link wrapping across lines).",
    },
  },
});
