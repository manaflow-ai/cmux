// l10n-allow-file: gallery fixtures, public-safe sample people, agents, spaces and threads.
// People (History > People, TeamDirectoryScreen.tsx, behind the `team-directory` experiment): RFD
// 0170's team navigator, recipient picker and a session's links, each answered in the shape acpmux's
// `_acpmux/team/*` RPCs send (cmux-team-messaging navigator.rs, picker.rs, session_info.rs). The
// fixtures stand in for the Rust: they return a fixed answer per method and do no matching.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { TeamDirectoryScreen } from "./TeamDirectoryScreen";

type Props = ComponentProps<typeof TeamDirectoryScreen>;

const live = (principalId: string, name: string, status: string, working = false) => ({
  principalId,
  name,
  status,
  working,
});
const ref = (kind: string, source: string, id: string) => ({ kind, source, id });

const navigator = {
  teams: [
    { id: "core", name: "Core", current: true, unread: 3 },
    { id: "cloud", name: "Cloud", current: false, unread: 1 },
  ],
  spaces: [
    {
      id: "s-design",
      title: "Design reviews",
      kind: "project",
      unread: 2,
      open: 5,
      people: [live("ada", "Ada", "active", true), live("grace", "Grace", "idle")],
      agents: [live("a-review", "Reviewer (Ada)", "active", true)],
    },
    {
      id: "s-ada-grace",
      title: "Ada and Grace",
      kind: "pair",
      unread: 1,
      open: 1,
      people: [live("grace", "Grace", "idle")],
      agents: [],
    },
    {
      id: "s-release",
      title: "Release train",
      kind: "project",
      unread: 0,
      open: 2,
      people: [live("linus", "Linus", "away")],
      agents: [live("a-ci", "CI watcher (Linus)", "active"), live("a-notes", "Release notes (Grace)", "idle")],
      // A preview of a busy space: 8 live rows shown of 23 (navigator.rs LIVE_PREVIEW).
      peopleLive: 14,
      agentsLive: 9,
    },
    { id: "s-archive", title: "Archive", kind: "project", unread: 0, open: 0, people: [], agents: [] },
  ],
  hits: [] as unknown[],
};

const hits = [
  { kind: "person", label: "Ada", id: "ada", detail: "Design reviews" },
  { kind: "agent", label: "Reviewer (Ada)", id: "a-review", detail: "Ada" },
  {
    kind: "thread",
    label: "Navigator spacing",
    id: "t-41",
    open: ref("thread", "cmux", "t-41"),
    detail: "Design reviews",
  },
  { kind: "rfd", label: "RFD 0170", id: "0170", open: ref("rfd", "hq", "0170"), detail: "Native team messaging" },
  {
    kind: "session",
    label: "Team navigator",
    id: "sa-7",
    open: ref("session", "cmux", "sa-7"),
    detail: "Design reviews",
  },
];

const picked = {
  resolved: [],
  candidates: [
    {
      kind: "person",
      id: "ada",
      label: "Ada",
      handle: "ada",
      spaceId: "s-ada-grace",
      grants: [],
      mode: "ask",
      wakeAllowed: false,
      status: "active",
      working: true,
    },
    {
      kind: "pairSpace",
      id: "s-ada-grace",
      label: "Ada and Grace",
      spaceId: "s-ada-grace",
      grants: [],
      mode: "ask",
      wakeAllowed: false,
      working: false,
    },
    {
      kind: "agent",
      id: "a-review",
      label: "Reviewer",
      handle: "reviewer",
      owner: "Ada",
      harness: "claude",
      sessionId: "sa-7",
      spaceId: "s-design",
      grants: [],
      mode: "wake",
      wakeAllowed: true,
      status: "active",
      working: true,
    },
    {
      kind: "space",
      id: "s-design",
      label: "Design reviews",
      spaceId: "s-design",
      grants: [],
      mode: "fyi",
      wakeAllowed: false,
      working: false,
    },
  ],
};

const sessionInfo = {
  session: ref("session", "cmux", "sa-7"),
  teamId: "core",
  teamName: "Core",
  spaceTitle: "Design reviews",
  spaceKind: "project",
  standing: "talk",
  grants: [],
  people: [
    { principalId: "ada", kind: "person", name: "Ada", standing: "owner", status: "active", working: true },
    { principalId: "grace", kind: "person", name: "Grace", standing: "view", status: null, working: false },
  ],
  agents: [
    {
      principalId: "a-review",
      kind: "agent",
      name: "Reviewer",
      standing: "talk",
      status: "active",
      working: true,
      owner: "Ada",
      harness: "claude",
    },
  ],
  threads: [
    { key: ref("thread", "cmux", "t-41"), subject: "Navigator spacing", spaceTitle: "Design reviews", state: "open" },
    { key: ref("thread", "cmux", "t-38"), subject: "Picker tiers", spaceTitle: "Design reviews", state: "closed" },
  ],
  rfds: [{ key: ref("rfd", "hq", "0170"), label: "RFD 0170", title: "Native team messaging" }],
  currentAsk: {
    messageId: "m-9",
    thread: ref("thread", "cmux", "t-41"),
    author: "Reviewer",
    authorKind: "agent",
    excerpt: "Tighter rows or keep 8px?",
  },
  feedback: [],
  actions: [
    { action: "openThread", target: ref("thread", "cmux", "t-41") },
    { action: "copyLink", link: "session:cmux/sa-7" },
  ],
};

const answer: Props["load"] = async (method, params) =>
  method === "navigator"
    ? { ...navigator, hits: String(params.query ?? "").trim() ? hits : [] }
    : method === "pick"
      ? picked
      : sessionInfo;

const base: Props = {
  load: answer,
  openSession: () => undefined,
  openRef: () => undefined,
  copy: async () => true,
};

export default componentEntry<Props>({
  id: "agent-pane.team-directory",
  title: "People",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/teamDirectory/TeamDirectoryScreen.tsx#TeamDirectoryScreen"],
  styles: () =>
    Promise.all([import("../../shared/styles.css"), import("../styles.css"), import("./teamDirectory.css")]),
  load: () => import("./TeamDirectoryScreen").then((module) => module.TeamDirectoryScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 560,
  anchors: [{ selector: ".tdir" }],
  variants: {
    navigator: {
      note: "The team navigator: two teams, the current team's spaces with unread and open counts and who is live in each (active, idle, away; working ringed; a busy space's preview ends in +N), and Send to beside it.",
      props: base,
    },
    search: {
      note: "A search across the team: a person, an agent, a thread, an RFD and a session, each tagged by kind; a session opens its links.",
      props: { ...base, initialQuery: "ad" },
    },
    "session-links": {
      note: "A session's links (Session Info): its open ask, linked threads and RFD, who is in it, Open chat and Copy link; Send to narrowed to an @handle.",
      props: { ...base, initialQuery: "ad", initialSessionId: "sa-7", initialPickQuery: "@rev" },
    },
    "pick-ambiguous": {
      note: "An @handle that names two people: the picker asks instead of guessing.",
      props: {
        ...base,
        initialPickQuery: "@al",
        load: async (method, params) =>
          method === "pick"
            ? { resolved: ["alex", "alice"], candidates: picked.candidates.slice(0, 1) }
            : answer(method, params),
      },
    },
    off: {
      note: "Team messaging is off in acpmux (meshRelay.teamMessaging): one quiet line instead of an empty list.",
      props: {
        ...base,
        load: async () =>
          Promise.reject({
            code: -32602,
            message: "team messaging is off: meshRelay in config.json names no hub, or sets teamMessaging false",
            data: { reason: "team_messaging_disabled" },
          }),
      },
    },
    "not-ready": {
      note: "The hub has not sent the address book yet.",
      props: {
        ...base,
        load: async () =>
          Promise.reject({ code: -32602, message: "not read yet", data: { reason: "team_directory_unavailable" } }),
      },
    },
    older: {
      note: "This Mac's acpmux predates the team directory.",
      props: { ...base, load: async () => Promise.reject({ code: -32601, message: "Method not found" }) },
    },
  },
});
