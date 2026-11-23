// l10n-allow-file: gallery labels and rows are fixture content, not shipped UI.
// Every kit piece (kit/index.ts) in a light and a dark panel side by side, each panel themed the
// way the app themes a page (ui/TokenSheet themedPanelStyle) and holding its own popups, so an
// open menu or popover takes its panel's theme. The session variants show the minimal sidebar look
// (cmux#45143) and the default row, both from the same kit pieces.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { SHEET_THEMES, themedPanelStyle } from "../ui/TokenSheet";
import { UiProvider } from "../ui/UiProvider";
import {
  Avatar,
  Button,
  DEFAULT_SESSION_LOOK,
  Field,
  Glass,
  GlassMenu,
  Icon,
  List,
  MINIMAL_SESSIONS_LOOK,
  Pill,
  PopoverButton,
  Row,
  SessionList,
  StatusGlyph,
  sessionLook,
  type Session,
  type SessionLook,
  type SessionState,
} from "./index";

type Scheme = "light" | "dark";
type Props = { show?: "primitives" | "sessions"; look?: "minimal" | "default" | "minimal-comfortable" };

function Panel({ scheme, children }: { scheme: Scheme; children: ReactNode }) {
  const [container, setContainer] = useState<HTMLElement | null>(null);
  return (
    <section
      ref={setContainer}
      className="kit-gallery-panel"
      style={themedPanelStyle(SHEET_THEMES[scheme])}
      aria-label={scheme === "light" ? "Light" : "Dark"}
      data-scheme={scheme}
    >
      <UiProvider container={container}>{children}</UiProvider>
    </section>
  );
}

function Primitives({ scheme }: { scheme: Scheme }) {
  const [picked, setPicked] = useState("inbox");
  const [last, setLast] = useState("none");
  return (
    <div className="kit-gallery-stack">
      <List title="Row and List">
        <Row
          title="Inbox"
          leading={<Icon name="inbox" size={16} row />}
          trailing={<Pill size="sm">12</Pill>}
          selected={picked === "inbox"}
          onSelect={() => setPicked("inbox")}
        />
        <Row
          title="Review queue"
          subtitle="3 waiting on you"
          density="comfortable"
          leading={<StatusGlyph name="waiting" size={12} />}
          selected={picked === "review"}
          onSelect={() => setPicked("review")}
        />
        <Row title="Static row, no action" leading={<Avatar name="Ada Lovelace" size="sm" />} />
      </List>
      <List title="Empty list" empty="Nothing here yet" />
      <div className="kit-gallery-line">
        <Pill>Neutral</Pill>
        <Pill tone="accent">Accent</Pill>
        <Pill tone="success">Merged</Pill>
        <Pill tone="attention">Needs you</Pill>
        <Pill tone="danger">Failed</Pill>
      </div>
      <div className="kit-gallery-line">
        {(["chrome", "popover", "menu", "chip"] as const).map((level) => (
          <Glass key={level} level={level} className="kit-gallery-glass">
            {level}
          </Glass>
        ))}
      </div>
      <div className="kit-gallery-line">
        <Avatar name="Ada Lovelace" size="sm" />
        <Avatar name="Ada Lovelace" />
        <Avatar name="Ada Lovelace" size="lg" />
        <Avatar name="Claude" shape="agent" size="lg" />
      </div>
      <div className="kit-gallery-line">
        <Button variant="solid">Primary</Button>
        <Button>Subtle</Button>
        <Button variant="ghost">Ghost</Button>
        <Button variant="ghost" icon aria-label="Settings">
          <Icon name="settings" size={16} />
        </Button>
        <GlassMenu
          label={`Actions ${scheme}`}
          trigger="Actions"
          items={[
            { id: "rename", label: "Rename", icon: "action.edit", shortcut: "⌘R", onSelect: () => setLast("rename") },
            { id: "pin", label: "Pin", icon: "action.pin", onSelect: () => setLast("pin") },
            { id: "sep", separator: true },
            { id: "close", label: "Close", danger: true, onSelect: () => setLast("close") },
          ]}
        />
        <PopoverButton label={`Details ${scheme}`} trigger="Details">
          <div className="kit-gallery-popover">
            <Field label="Name" defaultValue="Inbox" hint="Shown in the sidebar" />
          </div>
        </PopoverButton>
      </div>
      <Field label="Branch" defaultValue="lane/customize" hint="Created from feat-cmux-next" />
      <Field label="Port" defaultValue="80a" error="A port is a number" />
      <output className="kit-gallery-receipt" data-testid={`kit-receipt-${scheme}`}>
        {picked} · {last}
      </output>
    </div>
  );
}

const SESSIONS: Session[] = [
  {
    id: "a",
    name: "Fix sidebar gutters",
    state: "working",
    icon: "terminal",
    directory: "cmux",
    branch: "lane/gutters",
    tabCount: 3,
  },
  { id: "b", name: "Release notes", state: "waiting", icon: "file.text", directory: "cmux", branch: "notes" },
  { id: "c", name: "Cloud start speed", state: "permission", icon: "cloud", directory: "platform", branch: "main" },
  { id: "d", name: "Gallery capture race", state: "done", icon: "terminal", directory: "cmux", branch: "lane/gallery" },
  { id: "e", name: "Nightly sign step", state: "error", icon: "terminal", directory: "ci", branch: "nightly-next" },
  { id: "f", name: "Scratch", state: "idle", icon: "terminal", directory: "~", tabCount: 2 },
];

const STATUS_WORDS: Record<SessionState, string> = {
  idle: "Idle",
  working: "Working",
  waiting: "Waiting for you",
  permission: "Needs permission",
  done: "Done",
  error: "Failed",
};

const LOOKS: Record<NonNullable<Props["look"]>, SessionLook> = {
  minimal: MINIMAL_SESSIONS_LOOK,
  default: DEFAULT_SESSION_LOOK,
  // A theme file's keys over the minimal look: the same pieces at the comfortable height.
  "minimal-comfortable": sessionLook({ "sidebar.density": "comfortable" }, MINIMAL_SESSIONS_LOOK),
};

function Sessions({ scheme, look }: { scheme: Scheme; look: SessionLook }) {
  const [selected, setSelected] = useState("a");
  return (
    <div className="kit-gallery-sidebar">
      <SessionList
        sessions={SESSIONS}
        look={look}
        statusLabel={(state) => STATUS_WORDS[state]}
        label={`Sessions ${scheme}`}
        selectedId={selected}
        onSelect={setSelected}
      />
      <output className="kit-gallery-receipt" data-testid={`sessions-receipt-${scheme}`}>
        {selected}
      </output>
    </div>
  );
}

function KitGallery({ show = "primitives", look = "minimal" }: Props) {
  return (
    <div className="kit-gallery" data-gallery-capture="">
      {(["light", "dark"] as const).map((scheme) => (
        <Panel key={scheme} scheme={scheme}>
          {show === "primitives" ? <Primitives scheme={scheme} /> : <Sessions scheme={scheme} look={LOOKS[look]} />}
        </Panel>
      ))}
    </div>
  );
}

const pickRow: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Review queue/ });
  await ctx.waitFor(() => ctx.find({ testId: "kit-receipt-light" }).textContent?.startsWith("review") ?? false);
};

const openMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Actions dark" });
  await ctx.waitFor(() => document.querySelector('[data-scheme="dark"] [role="menu"]'));
};

const openPopover: Play = async (ctx) => {
  await ctx.click({ selector: '[data-scheme="light"] [aria-haspopup="dialog"]' });
  await ctx.waitFor(() => document.querySelector('[data-scheme="light"] [role="dialog"]'));
};

const pickSession: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Release notes/ });
  await ctx.waitFor(() => ctx.find({ testId: "sessions-receipt-light" }).textContent === "b");
};

export default componentEntry<Props>({
  id: "kit.primitives",
  title: "Kit: UI base for customizations",
  area: "UI primitives",
  height: 760,
  covers: [
    "kit/Row.tsx#Row",
    "kit/List.tsx#List",
    "kit/Pill.tsx#Pill",
    "kit/Avatar.tsx#Avatar",
    "kit/Field.tsx#Field",
    "kit/GlassMenu.tsx#GlassMenu",
    "kit/PopoverButton.tsx#PopoverButton",
    "kit/presets/SessionList.tsx#SessionList",
    "kit/presets/SessionList.tsx#MinimalSessions",
  ],
  load: async () => KitGallery,
  styles: () => Promise.all([import("./kit.css"), import("./kit.gallery.css")]),
  variants: {
    primitives: { props: { show: "primitives" }, note: "Every piece, light and dark." },
    "pick-row": { props: { show: "primitives" }, play: pickRow, note: "A row is the one open target." },
    "menu-open": { props: { show: "primitives" }, play: openMenu, note: "GlassMenu open in the dark panel." },
    "popover-open": { props: { show: "primitives" }, play: openPopover, note: "PopoverButton with a Field inside." },
    "minimal-sessions": {
      props: { show: "sessions", look: "minimal" },
      note: "cmux#45143's minimal sidebar on the kit: status first, then the name; idle draws nothing.",
    },
    "minimal-comfortable": {
      props: { show: "sessions", look: "minimal-comfortable" },
      note: "The minimal look with one theme-file key changed: sidebar.density comfortable.",
    },
    "default-sessions": {
      props: { show: "sessions", look: "default" },
      note: "The default row from the same pieces: icon, folder and branch, status at the end.",
    },
    "pick-session": { props: { show: "sessions", look: "minimal" }, play: pickSession },
  },
});
