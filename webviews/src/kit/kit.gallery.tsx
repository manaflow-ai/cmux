// l10n-allow-file: gallery labels and rows are fixture content, not shipped UI.
// Every kit piece (kit/index.ts) in a light and a dark panel side by side, each panel themed the
// way the app themes a page (ui/TokenSheet themedPanelStyle) and holding its own popups, so an
// open menu or popover takes its panel's theme. The session variants show the minimal sidebar look
// (cmux#45143) and the default row, both from the same kit pieces. Every other export (Tooltip, Menu,
// Card, Panel, the motion readers) shows here too; each is the app's own component, re-exported.
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { SHEET_THEMES, themedPanelStyle } from "../ui/TokenSheet";
import { UiProvider } from "../ui/UiProvider";
import {
  Avatar,
  Button,
  Card,
  DEFAULT_SESSION_LOOK,
  EASE_STANDARD,
  Field,
  Glass,
  GlassMenu,
  INSTRUMENT_VERSION,
  Icon,
  List,
  MINIMAL_SESSIONS_LOOK,
  MOTION,
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuItem,
  MenuPopup,
  MenuSeparator,
  Panel,
  Pill,
  PopoverButton,
  Row,
  SessionList,
  StatusGlyph,
  Tooltip,
  TooltipProvider,
  grid,
  motionMode,
  motionToken,
  sessionLook,
  type MotionMode,
  type Session,
  type SessionLook,
  type SessionState,
} from "./index";

type Scheme = "light" | "dark";
type Props = {
  show?: "primitives" | "pieces" | "sessions" | "variants";
  look?: "minimal" | "default" | "minimal-comfortable";
};

function Stage({ scheme, children }: { scheme: Scheme; children: ReactNode }) {
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

type MotionReading = { mode: MotionMode; values: string[] };

/** The motion steps as this panel resolves them: every token read in one pass, then one state write. */
function MotionSteps({ scheme }: { scheme: Scheme }) {
  const list = useRef<HTMLDListElement>(null);
  const [reading, setReading] = useState<MotionReading | null>(null);
  useLayoutEffect(() => {
    const node = list.current;
    if (!node) return;
    const doc = node.ownerDocument;
    const values = MOTION.map((step) => motionToken(node, step.variable, doc));
    setReading({ mode: motionMode(doc, node), values });
  }, []);
  return (
    <dl ref={list} className="kit-gallery-motion" aria-label={`Motion ${scheme}`}>
      {MOTION.map((step, index) => (
        <div key={step.name} className="kit-gallery-motion-step">
          <dt>{step.name}</dt>
          <dd>
            {step.ms} ms · {reading?.values[index] || step.variable}
          </dd>
        </div>
      ))}
      <div className="kit-gallery-motion-step">
        <dt>mode</dt>
        <dd data-testid={`motion-mode-${scheme}`}>{reading?.mode ?? "…"}</dd>
      </div>
      <div className="kit-gallery-motion-step">
        <dt>ease</dt>
        <dd>{EASE_STANDARD}</dd>
      </div>
    </dl>
  );
}

/** Tooltip, Menu, Card, Panel and the motion readers: the app's own components, through the kit. */
function Pieces({ scheme }: { scheme: Scheme }) {
  const [last, setLast] = useState("none");
  const [wrap, setWrap] = useState(true);
  const [cardAnchor, setCardAnchor] = useState<HTMLElement | null>(null);
  const [cardOpen, setCardOpen] = useState(false);
  return (
    <TooltipProvider>
      <div className="kit-gallery-stack">
        <div className="kit-gallery-line">
          <Tooltip label="Fork from here" detail="Start a new thread. This one stays as it is." shortcut="⌘D">
            <Button size="sm" aria-label={`Fork ${scheme}`}>
              Fork
            </Button>
          </Tooltip>
          <Menu>
            <MenuButton label={`Menu ${scheme}`} className="ui-btn" variant="subtle" size="md">
              Menu
            </MenuButton>
            <MenuPopup label={`Menu ${scheme}`}>
              <MenuItem shortcut="⌘R" onSelect={() => setLast("rename")}>
                Rename
              </MenuItem>
              <MenuItem onSelect={() => setLast("duplicate")}>Duplicate</MenuItem>
              <MenuCheckboxItem checked={wrap} onCheckedChange={setWrap}>
                Wrap lines
              </MenuCheckboxItem>
              <MenuSeparator />
              <MenuItem disabled>Archive</MenuItem>
            </MenuPopup>
          </Menu>
          <span ref={setCardAnchor}>
            <Button size="sm" aria-pressed={cardOpen} onClick={() => setCardOpen((open) => !open)}>
              {`Card ${scheme}`}
            </Button>
          </span>
          <Card anchor={cardOpen ? cardAnchor : null} ariaLabel={`Card ${scheme}`}>
            <div className="kit-gallery-card">
              <strong>lane/instrument-kit</strong>
              <span>3 commits ahead of feat-cmux-next</span>
            </div>
          </Card>
        </div>
        {/* oxlint-disable-next-line jsx-a11y/aria-role -- the Panel (Surface) role, not an ARIA role */}
        <Panel role="card" aria-label={`Panel ${scheme}`}>
          <Panel.Header icon={<Icon name="terminal" size={16} />} trailing={<Pill size="sm">2</Pill>}>
            Panel
          </Panel.Header>
          <Panel.Body>The surface every card, sheet and ask card is drawn with.</Panel.Body>
          <Panel.Inset mono>bun run typecheck</Panel.Inset>
          <Panel.Actions>
            <Panel.Action onClick={() => setLast("deny")}>Deny</Panel.Action>
            <Panel.Trailing>
              <Panel.Action kind="primary" onClick={() => setLast("allow")}>
                Allow
              </Panel.Action>
            </Panel.Trailing>
          </Panel.Actions>
        </Panel>
        <MotionSteps scheme={scheme} />
        <output className="kit-gallery-receipt" data-testid={`pieces-receipt-${scheme}`}>
          Instrument {INSTRUMENT_VERSION} · {last} · wrap {wrap ? "on" : "off"}
        </output>
      </div>
    </TooltipProvider>
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

/** The variants a host with its own sheet (a customize scene) builds with: a bare Button, a Row with
 * a detail second line, a host selection fill and drag handlers, the xs Pill, the grid lengths and
 * the full radius. Each reproduces a value the app already draws. */
function Variants({ scheme }: { scheme: Scheme }) {
  const [picked, setPicked] = useState("today");
  const [dragged, setDragged] = useState("none");
  return (
    <div className="kit-gallery-stack">
      <List title="Row: detail subtitle, host selection fill, passthrough">
        <Row
          title="Today"
          subtitle="Detail-size second line"
          subtitleSize="detail"
          className="kit-gallery-host-row"
          selected={picked === "today"}
          onSelect={() => setPicked("today")}
          draggable
          onDragStart={() => setDragged("today")}
        />
        <Row
          title="Tomorrow"
          subtitle="Caption-size second line (default)"
          selected={picked === "tomorrow"}
          onSelect={() => setPicked("tomorrow")}
        />
      </List>
      <div className="kit-gallery-line">
        <Pill size="xs">3</Pill>
        <Pill size="xs" className="kit-gallery-tinted">
          Tinted
        </Pill>
        <Pill size="xs" tone="success">
          Merged
        </Pill>
        <Pill size="sm">sm</Pill>
        <Pill>md</Pill>
      </div>
      <div className="kit-gallery-line">
        <Button bare className="kit-gallery-bare-button" onClick={() => setPicked("bare")}>
          Bare button, host-styled
        </Button>
        <Button>Default button</Button>
      </div>
      <div className="kit-gallery-line">
        {(["base", "gap", "icon-box", "row"] as const).map((name) => (
          <span
            key={name}
            className="kit-gallery-grid-swatch"
            style={{ width: grid(name), height: grid(name) }}
            title={name}
          />
        ))}
        <span className="kit-gallery-full-swatch" />
      </div>
      <output className="kit-gallery-receipt" data-testid={`variants-receipt-${scheme}`}>
        {picked} · {dragged}
      </output>
    </div>
  );
}

function KitGallery({ show = "primitives", look = "minimal" }: Props) {
  return (
    <div className="kit-gallery" data-gallery-capture="">
      {(["light", "dark"] as const).map((scheme) => (
        <Stage key={scheme} scheme={scheme}>
          {show === "primitives" ? (
            <Primitives scheme={scheme} />
          ) : show === "pieces" ? (
            <Pieces scheme={scheme} />
          ) : show === "variants" ? (
            <Variants scheme={scheme} />
          ) : (
            <Sessions scheme={scheme} look={LOOKS[look]} />
          )}
        </Stage>
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

const showTooltip: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: "Fork light" });
  await ctx.waitFor(() => document.querySelector('[data-scheme="light"] [role="tooltip"]'));
};

const openPiecesMenu: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Menu dark" });
  await ctx.waitFor(() => document.querySelector('[data-scheme="dark"] [role="menu"]'));
};

const openCards: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Card light" });
  await ctx.click({ role: "button", name: "Card dark" });
  await ctx.waitFor(() => document.querySelectorAll(".ui-card").length === 2);
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
    "ui/Tooltip.tsx#Tooltip",
    "ui/Tooltip.tsx#AnchoredCard",
    "ui/Menu.tsx#Menu",
    "ui/surface/Surface.tsx#Surface",
    "kit/presets/SessionList.tsx#SessionList",
    "kit/presets/SessionList.tsx#MinimalSessions",
  ],
  load: async () => KitGallery,
  styles: () => Promise.all([import("./kit.css"), import("./kit.gallery.css")]),
  variants: {
    primitives: { props: { show: "primitives" }, note: "Every piece, light and dark." },
    "pick-row": { props: { show: "primitives" }, play: pickRow, note: "A row is the one open target." },
    "menu-open": { props: { show: "primitives" }, play: openMenu, note: "GlassMenu open in the dark panel." },
    pieces: { props: { show: "pieces" }, note: "Tooltip, Menu, Card, Panel and motion, light and dark." },
    "tooltip-open": { props: { show: "pieces" }, play: showTooltip, note: "Tooltip on hover in the light panel." },
    "pieces-menu-open": { props: { show: "pieces" }, play: openPiecesMenu, note: "Menu open in the dark panel." },
    "card-open": { props: { show: "pieces" }, play: openCards, note: "Card (the app's hover card) in both panels." },
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
    "scene-parity": {
      props: { show: "variants" },
      note: "Variants for scene parity: bare Button, Row detail subtitle and host fill, xs Pill, grid lengths, full radius.",
    },
  },
});
