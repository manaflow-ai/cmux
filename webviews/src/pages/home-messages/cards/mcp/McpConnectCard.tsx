// The MCP connect card in one of its looks (Swift `McpConnectCardView` and its parts). Every look
// shows the same facts and the same controls; only the arrangement differs. Cancel and Connect
// carry their keys (Escape, Return), answered while focus is in the card. The card draws only the
// flow it is given; `useMcpConnectFlow` steps it and sends each step's effects as host ops.
import { useCallback, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Spinner } from "../../../../agent-session/acpmux/conversation/icons";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import { DialogButton } from "../../../../ui/DialogButton";
import { Select } from "../../../../ui/Select";
import type { Strings } from "../strings";
import {
  isRisky,
  MCP_SCOPES,
  McpConnectFlow,
  McpConnectKey,
  signInScopes,
  type McpCardStyle,
  type McpConnectCardData,
  type McpScope,
  type McpTool,
} from "./mcpConnect";
import { sendMcpEffects, type HostCall } from "./mcpHost";
import "../cards.css";

/** What the card's controls call. */
export interface McpConnectActions {
  choose(scope: McpScope): void;
  connect(): void;
  cancel(): void;
  submitKey(key: McpConnectKey): void;
}

export interface McpConnectCardProps {
  flow: McpConnectFlow;
  style?: McpCardStyle;
  strings: Strings;
  actions: McpConnectActions;
}

/** Holds a card's flow: each control steps it and sends the step's effects through `call`. */
export function useMcpConnectFlow(card: McpConnectCardData, call: HostCall) {
  const [flow, setFlow] = useState(() => McpConnectFlow.start(card));
  const current = useRef(flow);
  current.current = flow;
  const step = useCallback(
    (next: McpConnectFlow, effects: Parameters<typeof sendMcpEffects>[2]) => {
      current.current = next;
      setFlow(next);
      void sendMcpEffects(call, card.requestID, effects);
    },
    [call, card.requestID],
  );
  const actions: McpConnectActions = {
    choose: (scope) => step(current.current.choose(scope), []),
    connect: () => step(...current.current.connect()),
    cancel: () => step(...current.current.cancel()),
    submitKey: (key) => step(...current.current.submit(key)),
  };
  /** A daemon answer (`cmux.home.mcp.state`). */
  const answer = (apply: (flow: McpConnectFlow) => McpConnectFlow) => {
    const next = apply(current.current);
    current.current = next;
    setFlow(next);
  };
  return { flow, actions, answer };
}

export function McpConnectCard({ flow, style = "factsTable", strings, actions }: McpConnectCardProps) {
  const { card } = flow;
  const risky = isRisky(card);
  // Return and Escape press the card's primary and Cancel while focus is in it (not in the key
  // field, which answers its own Return).
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    // A focused button or the key field answers its own key.
    const tag = (event.target as HTMLElement).tagName;
    if (tag === "INPUT" || (tag === "BUTTON" && event.key === "Enter")) return;
    if (event.key === "Escape" && cancellable(flow)) {
      event.preventDefault();
      actions.cancel();
    } else if (event.key === "Enter" && flow.phase.kind === "ask" && style !== "twoStep") {
      event.preventDefault();
      actions.connect();
    }
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Return and Escape answer the card from any of its controls, as the Swift card's default and cancel keys do.
    <section
      className="hm-mcp"
      data-style={style}
      data-risky={risky ? "" : undefined}
      data-phase={flow.phase.kind}
      aria-label={strings.format("home.mcpConnect.title", card.title)}
      onKeyDown={onKeyDown}
    >
      <Body flow={flow} style={style} strings={strings} actions={actions} />
    </section>
  );
}

function cancellable(flow: McpConnectFlow): boolean {
  const kind = flow.phase.kind;
  return kind === "ask" || kind === "enterKey" || kind === "signingIn" || kind === "connecting";
}

function Body({ flow, style, strings, actions }: Required<McpConnectCardProps>) {
  switch (style) {
    case "compactRow":
      return <CompactRow flow={flow} strings={strings} actions={actions} />;
    case "permissionSheet":
      return <PermissionSheet flow={flow} strings={strings} actions={actions} />;
    case "twoStep":
      return <TwoStep flow={flow} strings={strings} actions={actions} />;
    case "bubble":
      return <Bubble flow={flow} strings={strings} actions={actions} />;
    case "dangerForward":
      return <FactsTable flow={flow} strings={strings} actions={actions} riskFirst />;
    case "factsTable":
      return <FactsTable flow={flow} strings={strings} actions={actions} riskFirst={false} />;
  }
}

type PartProps = { flow: McpConnectFlow; strings: Strings; actions: McpConnectActions };

/** Styles 2 and 6: title and badge, the agent's reason, the facts, the scope, the controls. */
function FactsTable({ flow, strings, actions, riskFirst }: PartProps & { riskFirst: boolean }) {
  const { card } = flow;
  return (
    <div className="hm-mcp__stack">
      {riskFirst && <RiskLines card={card} strings={strings} />}
      <div className="hm-mcp__head">
        <Mark title={card.title} size={28} />
        <span className="hm-mcp__title">{strings.format("home.mcpConnect.title", card.title)}</span>
        <Badge card={card} strings={strings} />
      </div>
      <Reason card={card} strings={strings} />
      <Facts card={card} strings={strings} />
      {flow.phase.kind === "ask" && (
        <div className="hm-mcp__scope-row">
          <span className="hm-mcp__label">{strings.t("home.mcpConnect.for")}</span>
          <ScopeMenu flow={flow} strings={strings} actions={actions} />
        </div>
      )}
      {!riskFirst && <RiskLines card={card} strings={strings} />}
      <Controls flow={flow} strings={strings} actions={actions} />
    </div>
  );
}

/** Style 1: one line (mark, "Connect X?", badge, Connect) with the facts behind Details. */
function CompactRow({ flow, strings, actions }: PartProps) {
  const { card } = flow;
  const [open, setOpen] = useState(false);
  return (
    <div className="hm-mcp__stack">
      <div className="hm-mcp__head">
        <Mark title={card.title} size={20} />
        <span className="hm-mcp__emphasis">{strings.format("home.mcpConnect.title", card.title)}</span>
        <Badge card={card} strings={strings} />
        <span className="hm-mcp__spacer" />
        {flow.phase.kind === "ask" && (
          <>
            <button type="button" className="hm-mcp__link" aria-expanded={open} onClick={() => setOpen(!open)}>
              {strings.t("home.mcpConnect.details")}
            </button>
            <DialogButton dialogKey="return" className="hm-mcp__primary" onClick={actions.connect}>
              {strings.t("home.mcpConnect.connect")}
            </DialogButton>
          </>
        )}
      </div>
      {(open || isRisky(card)) && <RiskLines card={card} strings={strings} />}
      {open && (
        <>
          <Reason card={card} strings={strings} />
          <Facts card={card} strings={strings} />
          <ScopeMenu flow={flow} strings={strings} actions={actions} />
        </>
      )}
      {flow.phase.kind !== "ask" && <Controls flow={flow} strings={strings} actions={actions} />}
    </div>
  );
}

/** Style 3: a big mark over "Connect X?", the access as bullets, then the server and the controls. */
function PermissionSheet({ flow, strings, actions }: PartProps) {
  const { card } = flow;
  const scopes = signInScopes(card);
  const bullets = scopes.length ? scopes : [accessText(card, strings)];
  return (
    <div className="hm-mcp__stack hm-mcp__stack--center">
      <Mark title={card.title} size={32} />
      <span className="hm-mcp__title">{strings.format("home.mcpConnect.title", card.title)}</span>
      <Badge card={card} strings={strings} />
      <Reason card={card} strings={strings} />
      <ul className="hm-mcp__bullets">
        {bullets.map((line) => (
          <li key={line}>{line}</li>
        ))}
      </ul>
      <Facts card={card} strings={strings} />
      <RiskLines card={card} strings={strings} />
      {flow.phase.kind === "ask" && <ScopeMenu flow={flow} strings={strings} actions={actions} />}
      <Controls flow={flow} strings={strings} actions={actions} />
    </div>
  );
}

/** Style 4: first "X wants to connect" with Review; Review shows the facts and Connect. */
function TwoStep({ flow, strings, actions }: PartProps) {
  const [reviewing, setReviewing] = useState(false);
  const { card } = flow;
  if (reviewing || flow.phase.kind !== "ask")
    return <FactsTable flow={flow} strings={strings} actions={actions} riskFirst={isRisky(card)} />;
  return (
    <div className="hm-mcp__head">
      <Mark title={card.title} size={28} />
      <span className="hm-mcp__names">
        <span className="hm-mcp__emphasis">
          {strings.format("home.mcpConnect.wantsAccess", `${card.agent} · ${card.title}`)}
        </span>
        <Badge card={card} strings={strings} />
      </span>
      <span className="hm-mcp__spacer" />
      <DialogButton dialogKey="escape" onClick={actions.cancel}>
        {strings.t("home.mcpConnect.cancel")}
      </DialogButton>
      <DialogButton dialogKey="return" className="hm-mcp__primary" onClick={() => setReviewing(true)}>
        {strings.t("home.mcpConnect.review")}
      </DialogButton>
    </div>
  );
}

/** Style 5: the card reads as the agent's message: its sentence first, the facts small, the buttons in it. */
function Bubble({ flow, strings, actions }: PartProps) {
  const { card } = flow;
  return (
    <div className="hm-mcp__stack">
      <span className="hm-mcp__emphasis">{strings.format("home.mcpConnect.title", card.title)}</span>
      {card.reason && <span className="hm-mcp__secondary">{card.reason}</span>}
      <span className="hm-mcp__line">
        <Badge card={card} strings={strings} />
        <span className="hm-mcp__label">·</span>
        <span className="hm-mcp__label">{accessText(card, strings)}</span>
      </span>
      <Facts card={card} strings={strings} />
      <RiskLines card={card} strings={strings} />
      {flow.phase.kind === "ask" && <ScopeMenu flow={flow} strings={strings} actions={actions} />}
      <Controls flow={flow} strings={strings} actions={actions} />
    </div>
  );
}

/** "Chief asks: …", the agent's own sentence in quotes. */
function Reason({ card, strings }: { card: McpConnectCardData; strings: Strings }) {
  if (!card.reason) return null;
  return (
    <span className="hm-mcp__reason">
      <span className="hm-mcp__label">{strings.format("home.mcpConnect.asks", card.agent)} </span>
      <span className="hm-mcp__secondary">“{card.reason}”</span>
    </span>
  );
}

/** The access line: what signing in grants. */
export function accessText(card: McpConnectCardData, strings: Strings): string {
  switch (card.auth.kind) {
    case "none":
      return strings.t("home.mcpConnect.noSignIn");
    case "oauth":
    case "device": {
      const signIn = strings.format("home.mcpConnect.signInWith", card.title);
      return card.auth.scopes.length ? `${card.auth.scopes.join(", ")} · ${signIn}` : signIn;
    }
    case "key":
      return strings.format("home.mcpConnect.key", card.auth.name);
  }
}

/** The lines that say why to look twice. */
export function riskLines(card: McpConnectCardData, strings: Strings): string[] {
  const out: string[] = [];
  if (card.transport.kind === "local") {
    out.push(strings.t("home.mcpConnect.riskLocal"));
    if (card.transport.fetchesCode) out.push(strings.t("home.mcpConnect.riskFetches"));
  } else if (!card.verified) {
    out.push(strings.t("home.mcpConnect.riskUnverified"));
  }
  if (card.idn) out.push(strings.t("home.mcpConnect.riskIDN"));
  return [...out, ...(card.warnings ?? [])];
}

/** The facts table: where it runs, who publishes it, what it gets. */
function Facts({ card, strings }: { card: McpConnectCardData; strings: Strings }) {
  const rows: [string, string, boolean][] =
    card.transport.kind === "remote"
      ? [[strings.t("home.mcpConnect.server"), card.transport.url, true]]
      : [
          [strings.t("home.mcpConnect.command"), card.transport.argv.join(" "), true],
          [strings.t("home.mcpConnect.binary"), `sha256:${card.transport.binarySHA256.slice(0, 16)}…`, true],
        ];
  rows.push(
    [strings.t("home.mcpConnect.by"), card.publisher, false],
    [strings.t("home.mcpConnect.access"), accessText(card, strings), false],
  );
  return (
    <dl className="hm-mcp__facts">
      {rows.map(([label, value, mono]) => (
        <div key={label} className="hm-mcp__fact">
          <dt className="hm-mcp__label">{label}</dt>
          <dd className={mono ? "hm-mcp__value hm-mcp__value--mono" : "hm-mcp__value"}>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function RiskLines({ card, strings }: { card: McpConnectCardData; strings: Strings }) {
  const lines = riskLines(card, strings);
  if (!lines.length) return null;
  return (
    <ul className="hm-mcp__risks">
      {lines.map((line) => (
        <li key={line}>
          <Icon name="status.warning" size={12} />
          {line}
        </li>
      ))}
    </ul>
  );
}

/** Verified (registry, exact URL) or Unverified. */
function Badge({ card, strings }: { card: McpConnectCardData; strings: Strings }) {
  const ok = card.verified && !card.idn;
  return (
    <span className="hm-mcp__badge" data-ok={ok ? "" : undefined}>
      <Icon name={ok ? "trust.verified" : "trust.invalid"} size={12} />
      {strings.t(ok ? "home.mcpConnect.verified" : "home.mcpConnect.unverified")}
    </span>
  );
}

function ScopeMenu({ flow, strings, actions }: PartProps) {
  return (
    <Select
      className="hm-mcp__scope"
      label={strings.t("home.mcpConnect.for")}
      value={flow.scope}
      options={MCP_SCOPES.map((scope) => ({ value: scope, label: strings.t(`home.mcpConnect.scope.${scope}`) }))}
      onChange={(value) => actions.choose(value as McpScope)}
      closeOnPick
    />
  );
}

/** Cancel and Connect (Return), or the private key field, or the phase line, by phase. */
function Controls({ flow, strings, actions }: PartProps) {
  const phase = flow.phase;
  switch (phase.kind) {
    case "ask":
      return (
        <div className="hm-mcp__buttons">
          <DialogButton dialogKey="escape" onClick={actions.cancel}>
            {strings.t("home.mcpConnect.cancel")}
          </DialogButton>
          <DialogButton dialogKey="return" className="hm-mcp__primary" onClick={actions.connect}>
            {strings.t("home.mcpConnect.connect")}
          </DialogButton>
        </div>
      );
    case "enterKey":
      return <KeyField flow={flow} strings={strings} actions={actions} />;
    case "signingIn":
      return <PhaseLine text={strings.t("home.mcpConnect.signingIn")} strings={strings} cancel={actions.cancel} />;
    case "connecting":
      return <PhaseLine text={strings.t("home.mcpConnect.connecting")} strings={strings} cancel={actions.cancel} />;
    case "connected":
      return <ToolList title={flow.card.title} tools={phase.tools} strings={strings} />;
    case "declined":
      return <span className="hm-mcp__label">{strings.t("home.mcpConnect.declined")}</span>;
    case "failed":
      return <span className="hm-mcp__failed">{strings.format("home.mcpConnect.failed", phase.reason)}</span>;
  }
}

/** The private key field: the typed key leaves the field on send and goes to the flow once. */
function KeyField({ flow, strings, actions }: PartProps) {
  const [key, setKey] = useState("");
  const auth = flow.card.auth;
  const name = auth.kind === "key" ? auth.name : "";
  const optional = auth.kind === "key" && auth.optional;
  const send = () => {
    if (!key.trim()) return;
    const typed = new McpConnectKey(key);
    setKey("");
    actions.submitKey(typed);
  };
  return (
    <div className="hm-mcp__key">
      <input
        type="password"
        className="hm-mcp__key-field"
        placeholder={name}
        aria-label={name}
        value={key}
        autoComplete="off"
        spellCheck={false}
        onChange={(event) => setKey(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            send();
          } else if (event.key === "Escape") {
            event.preventDefault();
            actions.cancel();
          }
        }}
      />
      <span className="hm-mcp__label">{strings.t("home.mcpConnect.keyPrivate")}</span>
      <div className="hm-mcp__buttons">
        {optional && (
          <button type="button" className="hm-mcp__link" onClick={() => actions.submitKey(new McpConnectKey(""))}>
            {strings.t("home.mcpConnect.skipKey")}
          </button>
        )}
        <span className="hm-mcp__spacer" />
        <DialogButton dialogKey="escape" onClick={actions.cancel}>
          {strings.t("home.mcpConnect.cancel")}
        </DialogButton>
        <DialogButton dialogKey="return" className="hm-mcp__primary" disabled={!key.trim()} onClick={send}>
          {strings.t("home.mcpConnect.save")}
        </DialogButton>
      </div>
    </div>
  );
}

/** A waiting line with Cancel. */
function PhaseLine({ text, strings, cancel }: { text: string; strings: Strings; cancel(): void }) {
  return (
    <output className="hm-mcp__phase">
      <Spinner size={12} loading />
      <span className="hm-mcp__secondary">{text}</span>
      <span className="hm-mcp__spacer" />
      <button type="button" className="hm-mcp__link" onClick={cancel}>
        {strings.t("home.mcpConnect.cancel")}
      </button>
    </output>
  );
}

const TOOL_ICON: Record<McpTool["kind"], string> = {
  read: "tool.read",
  write: "tool.edit",
  destructive: "action.delete",
};

/** The connected result: the count line and each tool with its class; a held tool says why. */
function ToolList({ title, tools, strings }: { title: string; tools: readonly McpTool[]; strings: Strings }) {
  const [open, setOpen] = useState(false);
  const writes = tools.filter((tool) => tool.kind !== "read").length;
  return (
    <div className="hm-mcp__tools">
      <button type="button" className="hm-mcp__connected" aria-expanded={open} onClick={() => setOpen(!open)}>
        <Icon name="status.success" size={14} />
        {strings.format("home.mcpConnect.connected", title, String(tools.length), String(writes))}
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
      </button>
      {open && (
        <ul className="hm-mcp__tool-list">
          {tools.map((tool) => (
            <li key={tool.name} data-flagged={tool.flagged ? "" : undefined}>
              <Icon name={tool.flagged ? "policy.reject" : TOOL_ICON[tool.kind]} size={12} />
              <span className="hm-mcp__value--mono">{tool.name}</span>
              {tool.flagged && <span className="hm-mcp__failed">{strings.t("home.mcpConnect.flagged")}</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** The server's mark: the first letter on a gray tile (no brand art is bundled). */
function Mark({ title, size }: { title: string; size: 20 | 28 | 32 }): ReactNode {
  return (
    <span className="hm-mcp__mark" data-size={size} aria-hidden="true">
      {title.slice(0, 1).toUpperCase()}
    </span>
  );
}
