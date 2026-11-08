// l10n-allow-file: gallery fixtures (the Swift playgrounds' sample servers, agents and links), not shipped UI.
// The cards drawn in a Home chat, in the states the Swift debug playgrounds showed
// (McpConnectCardPlayground, HomeAgentMessagePlayground, HomeNativeFixture, HomeFixtureMedia): every
// MCP card look for every kind of server in every phase, the pill shapes, the agent pane and its
// peek, link chips and their preview cards, the first-run panel and the header toggles.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { cardStrings } from "./strings";
import { McpConnectCard, useMcpConnectFlow } from "./mcp/McpConnectCard";
import {
  McpConnectFlow,
  McpConnectKey,
  type McpCardStyle,
  type McpConnectCardData,
  type McpTool,
} from "./mcp/mcpConnect";
import { AgentPills } from "./pills/AgentPills";
import { AgentChat } from "./pills/AgentChat";
import { AgentSidePane } from "./pills/AgentSidePane";
import {
  closeAgent,
  openAgent,
  selectAgent,
  type AgentChatContent,
  type AgentPaneState,
  type AgentPillShape,
  type AgentThreadSource,
} from "./pills/agentModel";
import { HomeLinkChip, LinkPreviewBody } from "./links/HomeLinkChip";
import type { HomeLinkPreview } from "./links/linkPreview";
import { FirstRunPanel, type FirstRunPanelProps, type StarterLook } from "./firstRun/FirstRunPanel";
import { chiefIntroText, starterPrompts, type AgentGlance, type SwitchKeys } from "./firstRun/firstRunModel";
import {
  HeaderPanelBar,
  headerPanelItems,
  type HeaderPanelContext,
  type HeaderPanelState,
} from "./header/HeaderPanelBar";

const strings = cardStrings();

// MCP Connect Card Playground's servers (Swift McpConnectCardFixture).
const SERVERS: Record<string, McpConnectCardData> = {
  linear: {
    requestID: "req_linear",
    agent: "Chief",
    reason: "to read and file the issues you mention",
    title: "Linear",
    publisher: "linear.app",
    verified: true,
    transport: { kind: "remote", url: "https://mcp.linear.app/mcp" },
    auth: { kind: "oauth", scopes: ["read", "write"] },
    proposedScope: "chief",
  },
  github: {
    requestID: "req_github",
    agent: "a12",
    reason: "to open the pull request for this fix",
    title: "GitHub",
    publisher: "githubcopilot.com",
    verified: true,
    transport: { kind: "remote", url: "https://api.githubcopilot.com/mcp/" },
    auth: { kind: "device", scopes: ["repo", "read:org"] },
    proposedScope: "chat",
  },
  context7: {
    requestID: "req_ctx7",
    agent: "Chief",
    reason: "to look up current library docs",
    title: "Context7",
    publisher: "context7.com",
    verified: true,
    transport: { kind: "remote", url: "https://mcp.context7.com/mcp" },
    auth: { kind: "key", name: "CONTEXT7_API_KEY", optional: true },
    proposedScope: "allChiefs",
  },
  customURL: {
    requestID: "req_custom",
    agent: "Chief",
    reason: "the README says to connect it",
    title: "mcp.acme-tools.dev",
    publisher: "acme-tools.dev",
    verified: false,
    transport: { kind: "remote", url: "https://mcp.acme-tools.dev/mcp" },
    auth: { kind: "oauth", scopes: [] },
    proposedScope: "chief",
  },
  lookalike: {
    requestID: "req_idn",
    agent: "a7",
    reason: "to file the bug in Linear",
    title: "mcp.xn--lnear-6ve.app",
    publisher: "xn--lnear-6ve.app",
    verified: false,
    idn: true,
    transport: { kind: "remote", url: "https://mcp.xn--lnear-6ve.app/mcp" },
    auth: { kind: "oauth", scopes: ["read", "write"] },
    proposedScope: "chat",
  },
  localCommand: {
    requestID: "req_local",
    agent: "Chief",
    reason: "to query the local Postgres",
    title: "postgres-mcp",
    publisher: "this Mac",
    verified: false,
    transport: {
      kind: "local",
      argv: ["npx", "-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/dev"],
      binarySHA256: "9f2c4e1b7a60d8c35e1f0a2b4c6d8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c0d",
      fetchesCode: true,
    },
    auth: { kind: "none" },
    proposedScope: "chief",
  },
};

const TOOLS: McpTool[] = [
  { name: "list_issues", kind: "read" },
  { name: "get_issue", kind: "read" },
  { name: "search_documentation", kind: "read" },
  { name: "create_issue", kind: "write" },
  { name: "update_issue", kind: "write" },
  { name: "create_comment", kind: "write" },
  { name: "delete_comment", kind: "destructive" },
];
const LOCAL_TOOLS: McpTool[] = [
  { name: "query", kind: "read" },
  { name: "list_tables", kind: "read" },
  { name: "describe_table", kind: "read", flagged: true },
];

type McpPhaseName = "ask" | "enterKey" | "signingIn" | "connecting" | "connected" | "declined" | "failed";

/** Walks a fresh flow to `phase` through the flow's own steps, so no variant shows a state the
 * flow cannot reach (McpConnectPlaygroundPhase.apply). */
function walk(card: McpConnectCardData, phase: McpPhaseName): McpConnectFlow {
  let flow = McpConnectFlow.start(card);
  if (phase === "ask") return flow;
  if (phase === "declined") return flow.cancel()[0];
  flow = flow.connect()[0];
  if (phase === "failed") return flow.failed("the server’s metadata names another resource");
  if (phase === "enterKey") return flow;
  if (flow.phase.kind === "enterKey") flow = flow.submit(new McpConnectKey("ctx7sk-demo"))[0];
  if (phase === "signingIn") return flow;
  flow = flow.signedIn();
  if (phase === "connecting") return flow;
  return flow.connected(card.transport.kind === "local" ? LOCAL_TOOLS : TOOLS);
}

function McpStage({ server, style, phase }: { server: string; style: McpCardStyle; phase: McpPhaseName }) {
  const card = SERVERS[server]!;
  // A live card: Connect, Cancel, the scope and the key step the real flow from the walked phase.
  const live = useMcpConnectFlow(card, async () => undefined);
  const [walked] = useState(() => walk(card, phase));
  const [stepped, setStepped] = useState(false);
  const flow = stepped ? live.flow : walked;
  const actions = {
    choose: (scope: Parameters<typeof live.actions.choose>[0]) => (setStepped(true), live.actions.choose(scope)),
    connect: () => (setStepped(true), live.actions.connect()),
    cancel: () => (setStepped(true), live.actions.cancel()),
    submitKey: (key: McpConnectKey) => (setStepped(true), live.actions.submitKey(key)),
  };
  return (
    <div className="hm-gallery-stage">
      <McpConnectCard flow={flow} style={style} strings={strings} actions={actions} />
    </div>
  );
}

// Agent Messages Playground's run (Swift HomeAgentPlaygroundAgent.all).
const AGENTS: AgentChatContent[] = [
  {
    peer: "a959",
    title: "Sidebar alignment fix",
    status: "Reported",
    task: "Sidebar alignment fix\nFix the sidebar alignment: the header and the New Workspace row share one left edge. Measure both in the real app at 100% and 200%, light and dark. Root cause first, then a failing test, then the fix. cmux-ci urgent, rebase, plain push to feat-cmux-next. Report OLD..NEW with before and after shots.",
    workedFor: "Worked for 5m 35s",
    details: [
      "Read SidebarHeaderView.swift and NewWorkspaceRow.swift",
      "Measured both rows: 16 pt and 12 pt",
      "Added a failing layout test (red on the fleet)",
      "Fixed the header inset; test green",
      "Pushed 41f05ff..631d310 to feat-cmux-next",
    ],
    messages: [
      {
        sender: "agent",
        text: "Root cause: the header used the window's safe-area inset (16 pt); the row used the sidebar's 12 pt padding.",
      },
      { sender: "agent", text: "Done: both rows now start at 12 pt. Landed `41f05ff..631d310` on feat-cmux-next." },
    ],
    workspaceLink: "cmux://chief/0a1b2c3d/session/s-959",
  },
  {
    peer: "a931",
    title: "Nightly appcast rebuild",
    status: "Working",
    task: "Nightly appcast rebuild\nRebuild the nightly appcast on an owned Mac mini, check the feed and the installed NIGHTLY are on the same build, then plain push.",
    workedFor: "Working for 2m 10s",
    details: ["Queued the nightly job on cmux-mini-3", "Waiting for the notarization step"],
    messages: [{ sender: "chief", text: "The fleet queue is clear now: bump your job with cmux-ci urgent." }],
    workspaceLink: "cmux://chief/0a1b2c3d/session/s-931",
    place: "cmux-mini-3",
  },
  {
    peer: "a940",
    title: "First-click button audit",
    status: "Queued",
    task: "First-click button audit\nAudit every button for first-click response, active and inactive window. Fix the causes and add a guard.",
    workedFor: "Queued for 48s",
    details: ["Listed 212 buttons in 38 views"],
    messages: [],
  },
  {
    peer: "a933",
    title: "a933",
    status: "Stopped without a report",
    task: "Chat switch scroll\n\nThe chat must show at the bottom on its first frame.",
    workedFor: "Stopped after 1m 12s",
    details: ["Its session is Disconnected"],
    messages: [{ sender: "agent", text: "(stopped without a report: its session is Disconnected)" }],
  },
];
const ROW = {
  peers: ["a959", "a931", "a940", "a933"],
  titles: ["Sidebar alignment fix", "Nightly appcast rebuild", "First-click button audit", "a933"],
  states: ["reported", "told", "queued", "stopped"],
};

function PillsStage({ shape, width }: { shape: AgentPillShape; width: number }) {
  const [opened, setOpened] = useState<string>();
  return (
    <div className="hm-gallery-stage" style={{ width }}>
      <AgentPills row={ROW} shape={shape} strings={strings} onOpen={setOpened} />
      {opened && <p className="hm-gallery-note">{opened}</p>}
    </div>
  );
}

function PaneStage({ tabs, selected }: { tabs: string[]; selected: string }) {
  const source: AgentThreadSource = { thread: () => undefined, markSeen: () => {}, send: () => {} };
  const [pane, setPane] = useState<AgentPaneState>({ tabs, selected });
  const content = (peer: string) => AGENTS.find((agent) => agent.peer === peer);
  return (
    <div className="hm-gallery-split">
      <div className="hm-gallery-stage">
        <AgentPills row={ROW} strings={strings} onOpen={(peer) => setPane(openAgent(pane, peer, source))} />
      </div>
      <AgentSidePane
        pane={pane}
        content={content}
        strings={strings}
        onSelect={(peer) => setPane(selectAgent(pane, peer, source))}
        onClose={(peer) => setPane(closeAgent(pane, peer, source))}
        onGoToWorkspace={() => {}}
        onSend={() => {}}
      />
    </div>
  );
}

function PeekStage({ peer }: { peer: string }) {
  return (
    <div className="hm-gallery-stage hm-gallery-peek">
      <AgentChat
        content={AGENTS.find((agent) => agent.peer === peer)!}
        compact
        strings={strings}
        actions={{ open: () => {}, close: () => {}, goToWorkspace: () => {} }}
      />
    </div>
  );
}

// HomeFixtureMedia's generated photo, as a page thumbnail.
const THUMBNAIL =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="300"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f2a64c"/><stop offset="1" stop-color="#334080"/></linearGradient></defs><rect width="600" height="300" fill="url(#g)"/></svg>',
  );

const PREVIEWS: Record<string, HomeLinkPreview> = {
  workspace: {
    kind: "workspace",
    title: "cmux-next sidebar",
    place: "Tabs: 3",
    status: "Open",
    statusTone: "success",
    lines: ["Chief", "zsh — ~/fun/cmux", "Sidebar alignment fix"],
  },
  terminal: {
    kind: "terminal",
    title: "zsh",
    place: "cmux-next sidebar · ~/fun/cmux",
    status: "Open",
    statusTone: "success",
    lines: ["$ cmux-ci status", "› Queued the nightly job on cmux-mini-3", "› Waiting for the notarization step"],
    monospaced: true,
  },
  browser: {
    kind: "browser",
    title: "Harbor at dusk",
    place: "http://localhost:5173/harbor",
    status: "Open",
    statusTone: "success",
    thumbnail: THUMBNAIL,
  },
  file: {
    kind: "markdown",
    title: "home.md",
    place: "~/fun/cmux/design",
    lines: [
      "# Home in React: the Messages view, its panels and sheets",
      "The docked Home's Messages view (the sidebar's Home entry).",
    ],
  },
  closed: { kind: "tab", title: "tab_0f3c9a1e2b4d5c6e7f8091a2b3c4d5e6", status: "Closed", statusTone: "danger" },
  session: {
    kind: "subagent",
    title: "Sidebar alignment fix",
    place: "cmux-next sidebar",
    status: "Open",
    statusTone: "success",
  },
};

const LINKS: { href: string; label: string; preview: string }[] = [
  { href: "cmux://workspace/ws_0f3c9a1e2b4d5c6e7f8091a2b3c4d5e6", label: "cmux-next sidebar", preview: "workspace" },
  { href: "cmux://tab/tab_1f3c9a1e2b4d5c6e7f8091a2b3c4d5e6", label: "zsh", preview: "terminal" },
  { href: "cmux://chief/0a1b2c3d/session/s-959", label: "a959", preview: "session" },
  { href: "file:///Users/me/fun/cmux/design/home.md", label: "home.md", preview: "file" },
  { href: "https://github.com/manaflow-ai/cmux/pull/36269", label: "manaflow-ai/cmux#36269", preview: "" },
];

function LinksStage({ cards }: { cards: string[] }) {
  const fetchPreview = async ({ url }: { url: string }) =>
    PREVIEWS[LINKS.find((link) => link.href === url)?.preview ?? ""];
  return (
    <div className="hm-gallery-stage">
      <p className="hm-gallery-message">
        {LINKS.map((link) => (
          <span key={link.href}>
            <HomeLinkChip href={link.href} label={link.label} fetchPreview={fetchPreview} onOpen={() => {}} />{" "}
          </span>
        ))}
      </p>
      <div className="hm-gallery-cards">
        {cards.map((name) => (
          <div key={name} className="ui-glass cv-link-preview hm-gallery-card">
            <div className="cv-link-preview__content">
              <LinkPreviewBody preview={PREVIEWS[name]!} />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

const SWITCH_KEYS: SwitchKeys = {
  tabByNumber: "⌃1…9",
  workspaceByNumber: "⌘1…9",
  nextPreviousTab: "⇧⌘[ ⇧⌘]",
  nextPreviousWorkspace: "⌃⌘[ ⌃⌘]",
  focusBackForward: "⌘[ ⌘]",
};
const GLANCES: AgentGlance[] = [
  { id: "tab_1", title: "Nightly appcast rebuild", icon: "agent.bot", status: "working" },
  { id: "tab_2", title: "Sidebar alignment fix", icon: "agent.bot", status: "done" },
  { id: "tab_3", title: "Image table rendering", icon: "agent.bot", status: "failed" },
  { id: "tab_4", title: "First-click button audit", icon: "agent.bot", status: "needsYou" },
  { id: "tab_5", title: "Docs pass", icon: "agent.bot", status: "idle" },
];

type FirstRunStage = Partial<Omit<FirstRunPanelProps, "strings">> & { height: number; look?: StarterLook };

function FirstRun({ height, look, ...rest }: FirstRunStage) {
  return (
    <div className="hm-gallery-first-run" style={{ height }}>
      <FirstRunPanel
        strings={strings}
        face={{ name: "Chief" }}
        shortcuts={{ agent: "⌘N", terminal: "⌘T" }}
        starterLook={look}
        onAction={() => {}}
        onAgent={() => {}}
        onStarter={() => {}}
        onHideSwitchKeys={() => {}}
        onOpenKeyboardSettings={() => {}}
        {...rest}
      />
    </div>
  );
}

function Header({
  context,
  states,
  enabled,
}: {
  context: HeaderPanelContext;
  states: HeaderPanelState[];
  enabled: boolean;
}) {
  const [on, setOn] = useState(states);
  const items = headerPanelItems(context, on, strings, enabled);
  return (
    <div className="hm-gallery-header">
      <span className="hm-gallery-header__name">Chief</span>
      <HeaderPanelBar
        items={items}
        onToggle={(id) =>
          setOn(
            on.some((state) => state.id === id)
              ? on.map((state) => (state.id === id ? { ...state, isOn: !state.isOn } : state))
              : [...on, { id, isOn: true }],
          )
        }
      />
    </div>
  );
}

type Props =
  | { card: "mcp"; server: string; style: McpCardStyle; phase: McpPhaseName }
  | { card: "pills"; shape: AgentPillShape; width: number }
  | { card: "pane"; tabs: string[]; selected: string }
  | { card: "peek"; peer: string }
  | { card: "links"; cards: string[] }
  | ({ card: "first-run" } & FirstRunStage)
  | { card: "header"; context: HeaderPanelContext; states: HeaderPanelState[]; enabled: boolean };

function Cards(props: Props) {
  switch (props.card) {
    case "mcp":
      return <McpStage {...props} />;
    case "pills":
      return <PillsStage {...props} />;
    case "pane":
      return <PaneStage {...props} />;
    case "peek":
      return <PeekStage {...props} />;
    case "links":
      return <LinksStage {...props} />;
    case "first-run": {
      const { card: _card, ...rest } = props;
      return <FirstRun {...rest} />;
    }
    case "header":
      return <Header {...props} />;
  }
}

const mcp = (server: string, style: McpCardStyle, phase: McpPhaseName, note: string) => ({
  note,
  props: { card: "mcp" as const, server, style, phase },
});

export default componentEntry<Props>({
  id: "home.messages-cards",
  title: "Home chat cards",
  area: "Home and Chief",
  height: 640,
  widths: { narrow: 390, normal: 768, wide: 1100 },
  covers: [
    "pages/home-messages/cards/mcp/McpConnectCard.tsx",
    "pages/home-messages/cards/pills/AgentPills.tsx",
    "pages/home-messages/cards/pills/AgentChat.tsx",
    "pages/home-messages/cards/pills/AgentSidePane.tsx",
    "pages/home-messages/cards/links/HomeLinkChip.tsx",
    "pages/home-messages/cards/firstRun/FirstRunPanel.tsx",
    "pages/home-messages/cards/header/HeaderPanelBar.tsx",
  ],
  load: async () => Cards,
  styles: () => import("./cards.gallery.css"),
  variants: {
    "mcp-facts-table": mcp(
      "linear",
      "factsTable",
      "ask",
      "Picked: the facts table, a verified OAuth server (the Swift default).",
    ),
    "mcp-danger-forward-local": mcp(
      "localCommand",
      "dangerForward",
      "ask",
      "The risk leads: a local command that downloads code.",
    ),
    "mcp-compact-row": mcp(
      "lookalike",
      "compactRow",
      "ask",
      "One line; an international look-alike keeps its risk lines open.",
    ),
    "mcp-permission-sheet": mcp("github", "permissionSheet", "ask", "A device-code server, the scopes as bullets."),
    "mcp-two-step": mcp("customURL", "twoStep", "ask", "First the ask, then Review shows the facts."),
    "mcp-bubble": mcp("linear", "bubble", "ask", "The card as the agent's message bubble."),
    "mcp-enter-key": mcp(
      "context7",
      "factsTable",
      "enterKey",
      "An optional-key server: the private field, Connect Without a Key.",
    ),
    "mcp-signing-in": mcp("github", "factsTable", "signingIn", "The sign-in page is open."),
    "mcp-connected": mcp("localCommand", "factsTable", "connected", "Connected: the count line; a held tool says why."),
    "mcp-failed": mcp("linear", "factsTable", "failed", "The daemon refused the server's metadata."),
    "mcp-declined": mcp("customURL", "factsTable", "declined", "Cancelled."),
    "pills-pill": {
      note: "Picked: the shipped capsules, one per agent.",
      props: { card: "pills", shape: "pill", width: 520 },
    },
    "pills-two-line": {
      note: "Two-line pills with the status words.",
      props: { card: "pills", shape: "twoLine", width: 520 },
    },
    "pills-chips": {
      note: "Chips keep one row: the ones that do not fit are left out.",
      props: { card: "pills", shape: "chip", width: 420 },
    },
    "agent-pane": {
      note: "Picked: the right pane, one tab per agent.",
      props: { card: "pane", tabs: ["a959", "a931"], selected: "a959" },
    },
    "agent-pane-moved": {
      note: "A moved agent names its machine.",
      props: { card: "pane", tabs: ["a931", "a940", "a933"], selected: "a931" },
    },
    "agent-peek": { note: "The peek: two task lines, the newest reply, Open.", props: { card: "peek", peer: "a959" } },
    "links-open": {
      note: "Chips, and the cards of open targets.",
      props: { card: "links", cards: ["workspace", "terminal", "browser"] },
    },
    "links-files-closed": {
      note: "A file's first lines and a target the app no longer has.",
      props: { card: "links", cards: ["file", "closed", "session"] },
    },
    "first-run-welcome": {
      note: "The only Chief's welcome over the hero, starters and rows.",
      props: {
        card: "first-run",
        height: 640,
        intro: chiefIntroText("welcome", strings),
        starters: starterPrompts({ workspaces: ["cmux-next sidebar"], working: ["Nightly appcast rebuild"] }, strings),
        switchKeys: SWITCH_KEYS,
      },
    },
    "first-run-focus-agents": {
      note: "A new Chief asks for its focus; the person's agents, most urgent first.",
      props: {
        card: "first-run",
        height: 640,
        intro: chiefIntroText("askFocus", strings),
        agents: GLANCES,
        memoryOffer: "Bring your memory from Claude Code",
        petShown: true,
      },
    },
    "first-run-conflict-stacked": {
      note: "Mission Control takes the tab keys; stacked starters.",
      props: {
        card: "first-run",
        height: 640,
        look: "stacked",
        starters: starterPrompts({}, strings),
        switchKeys: { ...SWITCH_KEYS, desktopConflict: true },
      },
    },
    "first-run-short": {
      note: "A short pane: agent rows go first, then the hero.",
      props: {
        card: "first-run",
        height: 260,
        agents: GLANCES,
        switchKeys: SWITCH_KEYS,
        starters: starterPrompts({}, strings),
      },
    },
    "header-chief": {
      note: "Picked: a local Chief's toggles, the right sidebar open.",
      props: {
        card: "header",
        context: { isChief: true },
        states: [{ id: "rightSidebar", isOn: true, shortcut: "⌥⌘B" }],
        enabled: true,
      },
    },
    "header-sharing": {
      note: "Sharing the screen with Chief: lit; the other toggles off by the Debug switch.",
      props: {
        card: "header",
        context: { isChief: true },
        states: [{ id: "screenShare", isOn: true }],
        enabled: false,
      },
    },
    "header-person": {
      note: "A chat with a person: only the right sidebar.",
      props: { card: "header", context: { isChief: false }, states: [], enabled: true },
    },
  },
});
