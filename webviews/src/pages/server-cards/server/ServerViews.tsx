// The Mac server's surfaces (plans/cmux-next/server.md 3, 6.2, 9 and 14; design/server-cards.md):
// the menu bar panel, the server's side of pairing, Health and the Add Server card. Each draws the
// app's status; every change is an intent the app's owner answers. Few labels by design: glyphs and
// dots carry state. Alert titles and bodies come from the server (they carry live numbers); check
// names are ours.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { DialogButton } from "../../../ui/DialogButton";
import { Switch } from "../../../ui/Switch";
import { cx } from "../../../ui/cx";
import type { Strings } from "../../shared/i18n";
import { formatBytes, formatRelative, formatTime, regionName } from "./format";
import { ServerIcon, type ServerIconName } from "./icons";
import {
  addServerButtons,
  buttonForKey,
  escapeTitleKey,
  HealthOrdering,
  isClickOnly,
  isOpen,
  layoutOf,
  overallOf,
  PairingCode,
  panelFacts,
  returnTitleKey,
  roleState,
  showsCandidate,
  usage,
  type AddServerAction,
} from "./model";
import type {
  HealthAlert,
  HealthSeverity,
  PairingCandidate,
  PairingOffer,
  ServerIntent,
  ServerRoleState,
  ServerSnapshot,
  ServerStatus,
} from "./types";

export type PanelLayout = "compact" | "dashboard" | "list";
export type PairingLayout = "code" | "qr" | "words";
export type HealthLayout = "checklist" | "summary" | "timeline";
export type WordsLayout = "grid" | "row" | "line";

/** The picks among the gallery's layouts (design/server-cards.md). */
export const PICKS = { panel: "compact", pairing: "code", health: "checklist", words: "grid" } as const;

/** What the panel, pairing and Health surfaces ask of the app. */
export interface ServerActions {
  send(intent: ServerIntent): void;
  /** The panel's Health row: Health in the same popover. */
  openHealth(): void;
}

const CHECK_KEYS: Record<string, string> = {
  "power.onBattery": "check.power",
  "network.offline": "check.network",
  "disk.low": "check.disk",
  "lock.pending": "check.lock",
  "sleep.enabled": "check.sleep",
  "restart.noAutoRestart": "check.autoRestart",
  "restart.fileVaultWait": "check.fileVault",
  "restart.notLoggedIn": "check.login",
  "linger.off": "check.linger",
  "encryption.off": "check.encryption",
  "postgres.quota": "check.quota",
  "backup.stale": "check.backup",
};

/** The check's name, neutral so it reads for a passing check too; a check this app does not know
 * reads by `fallback` (the server's title). */
export function checkName(strings: Strings, check: string, fallback: string): string {
  const key = CHECK_KEYS[check];
  return key ? strings.t(key) : fallback;
}

function stateText(
  strings: Strings,
  state: ServerRoleState | "running" | "stopped" | "draining" | "crashloop",
): string {
  if (state === "on" || state === "running") return strings.t("status.serving");
  if (state === "off" || state === "stopped") return strings.t("status.off");
  return strings.t(`state.${state}`);
}

function overallLabel(strings: Strings, status: ServerStatus): { text: string; tone: string } {
  const overall = overallOf(status);
  switch (overall.kind) {
    case "unavailable":
      return { text: strings.t("status.unreachable"), tone: "muted" };
    case "off":
      return { text: strings.t("status.off"), tone: "muted" };
    case "unpaired":
      return { text: strings.t("status.unpaired"), tone: "secondary" };
    case "pairing":
      return { text: strings.t("status.pairing"), tone: "secondary" };
    case "serving":
      return { text: strings.t("status.serving"), tone: "ok" };
    case "attention":
      return { text: strings.t("status.attention"), tone: overall.severity };
  }
}

// MARK: - Shared pieces

function Dot({ tone, large }: { tone?: string; large?: boolean }) {
  return <span className="sv-dot" data-tone={tone} data-size={large ? "8" : undefined} aria-hidden="true" />;
}

function Row({
  icon,
  title,
  value,
  tone,
  onClick,
  name,
}: {
  icon: ServerIconName;
  title: string;
  value?: string;
  tone?: string;
  onClick?: () => void;
  name?: string;
}) {
  const body = (
    <>
      <ServerIcon name={icon} className="sv-row-icon" />
      <span className="sv-grow">{title}</span>
      <span className="sv-row-trailing">
        {tone && <Dot tone={tone} />}
        {value !== undefined && <span>{value}</span>}
        {onClick && <ServerIcon name="chevron" size={12} className="sv-tertiary" />}
      </span>
    </>
  );
  return onClick ? (
    <button type="button" className="sv-row" data-row={name} onClick={onClick}>
      {body}
    </button>
  ) : (
    <div className="sv-row" data-row={name}>
      {body}
    </div>
  );
}

function Pill({
  title,
  icon,
  prominent,
  help,
  disabled,
  onClick,
  data,
}: {
  title: string;
  icon?: ServerIconName;
  prominent?: boolean;
  help?: string;
  disabled?: boolean;
  onClick: () => void;
  data?: Record<`data-${string}`, string>;
}) {
  return (
    <button
      type="button"
      className="sv-pill"
      data-prominent={prominent ? "" : undefined}
      title={help}
      disabled={disabled}
      onClick={onClick}
      {...data}
    >
      {icon && <ServerIcon name={icon} size={12} />}
      {title}
    </button>
  );
}

function FixButton({
  alert,
  status,
  actions,
  strings,
}: {
  alert: HealthAlert;
  status: ServerStatus;
  actions: ServerActions;
  strings: Strings;
}) {
  const fix = alert.fix;
  if (!fix) return null;
  return (
    <Pill
      title={fix.title}
      icon={fix.needsAdmin ? "lock" : fix.opensSettings ? "external" : undefined}
      help={fix.needsAdmin ? strings.t("fix.admin") : undefined}
      disabled={status.pending.fixing.includes(alert.check)}
      onClick={() => actions.send({ kind: "fixCheck", check: alert.check })}
      data={{ "data-fix": alert.check }}
    />
  );
}

function severityIcon(severity: HealthSeverity | undefined): ServerIconName {
  return severity ?? "ok";
}

function CheckGlyph({ severity }: { severity?: HealthSeverity }) {
  return (
    <span className="sv-glyph" data-tone={severity ?? "ok"}>
      <ServerIcon name={severityIcon(severity)} size={16} />
    </span>
  );
}

function Reject({ status }: { status: ServerStatus }) {
  if (status.lastReject === undefined) return null;
  return (
    <p className="sv-reject" role="alert">
      {status.lastReject}
    </p>
  );
}

/** Host name, overall state and the on/off switch: the top of the panel and the pairing view. */
function ServerHeader({
  status,
  actions,
  strings,
}: {
  status: ServerStatus;
  actions: ServerActions;
  strings: Strings;
}) {
  const snapshot = status.snapshot;
  const label = overallLabel(strings, status);
  const team = snapshot?.enabled && snapshot.pairing.state === "paired" ? snapshot.pairing.team : undefined;
  return (
    <header className="sv-header">
      <ServerIcon name={snapshot?.platform === "macos" ? "mac" : "server"} className="sv-secondary" />
      <span className="sv-stack sv-grow">
        <span className="sv-emphasis">{snapshot?.hostName ?? strings.t("panel.title")}</span>
        <span className="sv-header-state">
          <Dot tone={label.tone} />
          <span>{team ? `${label.text} · ${team}` : label.text}</span>
        </span>
      </span>
      {snapshot && (
        <Switch
          size="sm"
          checked={snapshot.enabled}
          aria-label={strings.t("panel.title")}
          data-server-switch=""
          disabled={status.pending.switching}
          onCheckedChange={(on) => actions.send({ kind: "setEnabled", on })}
        />
      )}
    </header>
  );
}

function StoreLine({ snapshot, strings }: { snapshot: ServerSnapshot; strings: Strings }) {
  return (
    <div className="sv-store">
      <span>{`cmux ${snapshot.store.version} · ${snapshot.store.channel}`}</span>
      {snapshot.store.pinned && (
        <span title={strings.t("store.pinned")}>
          <ServerIcon name="pin" size={12} />
        </span>
      )}
    </div>
  );
}

function ChiefRow({ status, strings }: { status: ServerStatus; strings: Strings }) {
  const chief = status.chief;
  if (!chief) return null;
  const reply =
    chief.lastReply !== undefined ? formatRelative(chief.lastReply, strings.language) : strings.t("chief.noReply");
  const tone = chief.state === "ready" ? "ok" : chief.state === "thinking" ? "secondary" : "critical";
  return (
    <Row
      icon="chief"
      title={strings.format("chief.on", chief.serverName)}
      value={`${strings.t(`chief.${chief.state}`)} · ${reply}`}
      tone={tone}
      name="chief"
    />
  );
}

// MARK: - Panel

interface SurfaceProps {
  status: ServerStatus;
  actions: ServerActions;
  strings: Strings;
}

/** The menu bar panel: the header with the switch, one of three layouts, the last refusal, the store
 * line and where the Chief runs. */
export function ServerPanel({
  status,
  actions,
  strings,
  layout = PICKS.panel,
}: SurfaceProps & { layout?: PanelLayout }) {
  const snapshot = status.snapshot;
  const props = { status, actions, strings };
  return (
    <div className="sv-surface" data-surface="panel" data-layout={layout}>
      <ServerHeader {...props} />
      {snapshot && (
        <>
          {layout === "compact" && <CompactPanel {...props} snapshot={snapshot} />}
          {layout === "dashboard" && <DashboardPanel {...props} snapshot={snapshot} />}
          {layout === "list" && <ListPanel {...props} snapshot={snapshot} />}
          <Reject status={status} />
          <StoreLine snapshot={snapshot} strings={strings} />
        </>
      )}
      <ChiefRow status={status} strings={strings} />
    </div>
  );
}

type PanelProps = SurfaceProps & { snapshot: ServerSnapshot };

function healthValue(strings: Strings, issues: number) {
  return issues === 0 ? strings.t("health.ok") : String(issues);
}

function databaseValue(snapshot: ServerSnapshot, strings: Strings) {
  const facts = panelFacts(snapshot);
  return facts.hasDatabases ? formatBytes(facts.databaseBytes, strings.language) : "–";
}

function PairRow({ snapshot, actions, strings }: PanelProps) {
  if (snapshot.pairing.state !== "unpaired") return null;
  const offer = snapshot.pairing.offer;
  return offer ? (
    <Row icon="qr" title={strings.t("action.pair")} value={PairingCode.display(offer.code)} name="pair" />
  ) : (
    <Row
      icon="qr"
      title={strings.t("action.pair")}
      value=""
      onClick={() => actions.send({ kind: "showPairingCode" })}
      name="pair"
    />
  );
}

function CompactPanel(props: PanelProps) {
  const { snapshot, actions, strings } = props;
  const facts = panelFacts(snapshot);
  return (
    <div className="sv-rows" data-divided="">
      <Row icon="terminal" title={strings.t("row.terminals")} value={String(snapshot.terminals)} />
      <Row
        icon="apps"
        title={strings.t("row.apps")}
        value={facts.appsValue}
        tone={facts.appsTroubled ? "critical" : undefined}
      />
      <Row icon="database" title={strings.t("row.database")} value={databaseValue(snapshot, strings)} />
      <Row
        icon="health"
        title={strings.t("row.health")}
        value={healthValue(strings, facts.issues.length)}
        tone={facts.worstIssue}
        onClick={actions.openHealth}
        name="health"
      />
      <PairRow {...props} />
    </div>
  );
}

function browserValue(snapshot: ServerSnapshot, strings: Strings) {
  switch (snapshot.browser.state) {
    case "off":
      return strings.t("status.off");
    case "idle":
      return "0";
    case "running":
      return String(snapshot.browser.pages);
    case "unavailable":
      return strings.t("state.unavailable");
  }
}

function RoleCard({
  icon,
  title,
  value,
  state,
  meter,
  tone,
  onClick,
  strings,
}: {
  icon: ServerIconName;
  title: string;
  value: string;
  state: ServerRoleState;
  meter?: number;
  tone?: string;
  onClick?: () => void;
  strings: Strings;
}) {
  const dim = state === "off" || state === "unavailable";
  const dot = tone ?? (state === "failed" ? "critical" : state === "starting" ? "warning" : undefined);
  const body = (
    <>
      <span className="sv-role-head">
        <ServerIcon name={icon} size={12} />
        <span className="sv-grow sv-ellipsis">{title}</span>
        {dot && <Dot tone={dot} />}
      </span>
      <span className="sv-role-value" data-dim={dim ? "" : undefined}>
        {dim ? stateText(strings, state) : value}
      </span>
      {meter !== undefined && !dim && (
        <span className="sv-meter" data-high={meter > 0.8 ? "" : undefined}>
          <span style={{ width: `${Math.max(meter * 100, 2)}%` }} />
        </span>
      )}
    </>
  );
  return onClick ? (
    <button type="button" className="sv-role" onClick={onClick}>
      {body}
    </button>
  ) : (
    <div className="sv-role">{body}</div>
  );
}

function DashboardPanel(props: PanelProps) {
  const { snapshot, actions, strings } = props;
  const facts = panelFacts(snapshot);
  const meter = snapshot.databases.length > 0 ? Math.max(...snapshot.databases.map(usage)) : undefined;
  return (
    <div className="sv-stack" data-gap="2">
      <div className="sv-role-grid">
        <RoleCard
          icon="terminal"
          title={strings.t("row.terminals")}
          value={String(snapshot.terminals)}
          state={roleState(snapshot, "session")}
          strings={strings}
        />
        <RoleCard
          icon="apps"
          title={strings.t("row.apps")}
          value={facts.appsValue}
          state={facts.appsTroubled ? "failed" : roleState(snapshot, "apps")}
          strings={strings}
        />
        <RoleCard
          icon="database"
          title={strings.t("row.database")}
          value={databaseValue(snapshot, strings)}
          state={roleState(snapshot, "postgres")}
          meter={meter}
          strings={strings}
        />
        <RoleCard
          icon="browser"
          title={strings.t("row.browser")}
          value={browserValue(snapshot, strings)}
          state={roleState(snapshot, "browser")}
          strings={strings}
        />
        <RoleCard
          icon="automation"
          title={strings.t("row.automations")}
          value={String(snapshot.automations)}
          state={roleState(snapshot, "automations")}
          strings={strings}
        />
        <RoleCard
          icon="health"
          title={strings.t("row.health")}
          value={healthValue(strings, facts.issues.length)}
          state="on"
          tone={facts.worstIssue ?? "ok"}
          onClick={actions.openHealth}
          strings={strings}
        />
      </div>
      <PairingCard {...props} />
    </div>
  );
}

function PairingCard({ snapshot, actions, strings }: PanelProps) {
  const pairing = snapshot.pairing;
  let body: ReactNode;
  if (pairing.state === "unpaired" && pairing.offer) {
    body = (
      <>
        <QR offer={pairing.offer} size={44} />
        <span className="sv-stack sv-grow">
          <span className="sv-code" data-size="m">
            {PairingCode.display(pairing.offer.code)}
          </span>
          <span className="sv-caption">
            {strings.format("pairing.expires", formatTime(pairing.offer.expiresAt, strings.language))}
          </span>
        </span>
      </>
    );
  } else if (pairing.state === "unpaired") {
    body = (
      <>
        <ServerIcon name="qr" />
        <span className="sv-secondary sv-grow">{strings.t("status.unpaired")}</span>
        <Pill
          title={strings.t("action.pair")}
          onClick={() => actions.send({ kind: "showPairingCode" })}
          data={{ "data-pair": "" }}
        />
      </>
    );
  } else if (pairing.state === "pairing") {
    body = (
      <>
        <ServerIcon name="pairing" />
        <span className="sv-secondary sv-grow">{strings.t("status.pairing")}</span>
      </>
    );
  } else {
    body = (
      <>
        <ServerIcon name="team" />
        <span className="sv-stack sv-grow">
          <span>{`${pairing.team} · ${pairing.owner}`}</span>
          <span className="sv-caption sv-mono">{pairing.hostID}</span>
        </span>
        <span className="sv-secondary">{snapshot.devices.length}</span>
        <ServerIcon name="devices" size={12} className="sv-tertiary" />
      </>
    );
  }
  return <div className="sv-box sv-pairing-box">{body}</div>;
}

function appTone(state: string) {
  if (state === "running") return "ok";
  if (state === "starting" || state === "draining") return "warning";
  return state === "crashloop" ? "critical" : "muted";
}

const DEVICE_ICONS: Record<string, ServerIconName> = { mac: "mac", phone: "phone", web: "browser", cli: "terminal" };

function ListPanel(props: PanelProps) {
  const { snapshot, status, actions, strings } = props;
  const open = HealthOrdering.open(snapshot.alerts);
  return (
    <div className="sv-rows" data-divided="">
      <PairRow {...props} />
      <Row icon="terminal" title={strings.t("row.terminals")} value={String(snapshot.terminals)} />
      {snapshot.appServers.length > 0 && <h4 className="sv-group">{strings.t("row.apps")}</h4>}
      {snapshot.appServers.map((app) => (
        <div key={app.appID} className="sv-row" data-app={app.appID}>
          <span className="sv-row-icon sv-center-dot">
            <Dot tone={app.holdsLease ? appTone(app.state) : "faint"} />
          </span>
          <span className="sv-grow" data-dim={app.holdsLease ? undefined : ""}>
            {app.name}
          </span>
          {app.durability === "zero-loss" && (
            <span title={strings.t("app.zeroLoss")} className="sv-tertiary">
              <ServerIcon name="cloud" size={12} />
            </span>
          )}
          <span className="sv-caption" data-tone={app.state === "crashloop" ? "critical" : undefined}>
            {app.holdsLease ? stateText(strings, app.state) : strings.t("app.elsewhere")}
          </span>
        </div>
      ))}
      <h4 className="sv-group">{strings.t("row.health")}</h4>
      {open.length === 0 && (
        <button type="button" className="sv-row" onClick={actions.openHealth} data-row="health">
          <span className="sv-row-icon sv-center-dot">
            <Dot tone="ok" />
          </span>
          <span className="sv-grow sv-secondary">{strings.t("health.ok")}</span>
        </button>
      )}
      {open.map((alert) => (
        <div key={`${alert.check}@${alert.raisedAt}`} className="sv-row" data-alert={alert.check} data-tall="">
          <span className="sv-row-icon sv-center-dot">
            <Dot tone={alert.severity} />
          </span>
          <span className="sv-stack sv-grow">
            <span>{checkName(strings, alert.check, alert.title)}</span>
            <span className="sv-caption sv-clamp">{alert.title}</span>
          </span>
          <FixButton alert={alert} status={status} actions={actions} strings={strings} />
        </div>
      ))}
      {snapshot.devices.length > 0 && <h4 className="sv-group">{strings.t("row.devices")}</h4>}
      {snapshot.devices.map((device) => (
        <div key={device.id} className="sv-row sv-device" data-device={device.id}>
          <ServerIcon name={DEVICE_ICONS[device.kind] ?? "devices"} className="sv-row-icon" />
          <span className="sv-grow">{device.name}</span>
          {device.lastSeen !== undefined && (
            <span className="sv-caption sv-device-seen">{formatTime(device.lastSeen, strings.language)}</span>
          )}
          {/* Revoke shows while the pointer or the keys are on the row; only the person's own click sends it. */}
          <Pill
            title={strings.t("action.revoke")}
            disabled={status.pending.revoking.includes(device.id)}
            onClick={() => actions.send({ kind: "revokeDevice", device: device.id })}
            data={{ "data-revoke": device.id }}
          />
        </div>
      ))}
    </div>
  );
}

// MARK: - Pairing (the server's side)

function QR({ offer, size }: { offer: PairingOffer; size: 44 | 92 | 196 }) {
  if (!offer.qr) return null;
  return <img className="sv-qr" src={offer.qr} width={size} height={size} alt="" draggable={false} />;
}

function Words({ words, size, layout = "grid" }: { words: string[]; size: "s" | "m" | "l"; layout?: WordsLayout }) {
  if (layout === "line")
    return (
      <p className="sv-words-line" data-size={size}>
        {words.join(" · ")}
      </p>
    );
  return (
    <ol className="sv-words" data-layout={layout} data-size={size}>
      {words.map((word, index) => (
        <li key={index} className="sv-word">
          <span className="sv-word-index">{index + 1}</span>
          <span className="sv-emphasis">{word}</span>
        </li>
      ))}
    </ol>
  );
}

/** What the server shows while it waits for a signed-in device to approve (server.md 6.2 step 2). */
export function ServerPairing({
  status,
  actions,
  strings,
  layout = PICKS.pairing,
}: SurfaceProps & { layout?: PairingLayout }) {
  const pairing = status.snapshot?.pairing;
  const offer = pairing?.state === "unpaired" ? pairing.offer : undefined;
  return (
    <div className="sv-surface" data-surface="pairing" data-layout={layout}>
      <ServerHeader status={status} actions={actions} strings={strings} />
      {offer && layout === "code" && (
        <div className="sv-stack" data-gap="3">
          <span className="sv-stack sv-center">
            <span className="sv-code" data-size="xl">
              {PairingCode.display(offer.code)}
            </span>
            <span className="sv-secondary">{strings.t("pairing.enter")}</span>
          </span>
          <span className="sv-split">
            <QR offer={offer} size={92} />
            <span className="sv-stack sv-grow">
              <Words words={offer.words} size="s" />
              <span className="sv-caption">{strings.t("pairing.words")}</span>
            </span>
          </span>
        </div>
      )}
      {offer && layout === "qr" && (
        <div className="sv-stack sv-center" data-gap="2">
          <span className="sv-qr-tile">
            <QR offer={offer} size={196} />
          </span>
          <span className="sv-secondary">{strings.t("pairing.scan")}</span>
          <span className="sv-code" data-size="l">
            {PairingCode.display(offer.code)}
          </span>
          <Words words={offer.words} size="s" layout="line" />
        </div>
      )}
      {offer && layout === "words" && (
        <div className="sv-stack" data-gap="3">
          <span className="sv-secondary">{strings.t("pairing.words")}</span>
          <Words words={offer.words} size="l" />
          <span className="sv-box sv-code-field">
            <span className="sv-caption">{strings.t("pairing.code")}</span>
            <span className="sv-code" data-size="m">
              {PairingCode.display(offer.code)}
            </span>
          </span>
        </div>
      )}
      {offer && (
        <span className="sv-caption sv-center">
          {strings.format("pairing.expires", formatTime(offer.expiresAt, strings.language))}
        </span>
      )}
      {pairing?.state === "unpaired" && !offer && (
        <div className="sv-center sv-pairing-empty">
          <Pill
            title={strings.t("action.pair")}
            prominent
            disabled={status.pending.pairing}
            onClick={() => actions.send({ kind: "showPairingCode" })}
            data={{ "data-pair": "" }}
          />
        </div>
      )}
      {pairing?.state === "pairing" && <Badge icon="pairing" title={strings.t("status.pairing")} />}
      {pairing?.state === "paired" && (
        <Badge icon="paired" title={strings.t("pairing.paired")} detail={`${pairing.team} · ${pairing.owner}`} />
      )}
      <Reject status={status} />
    </div>
  );
}

function Badge({ icon, title, detail }: { icon: ServerIconName; title: string; detail?: string }) {
  return (
    <div className="sv-badge sv-stack sv-center">
      <ServerIcon name={icon} size={32} />
      <span className="sv-emphasis sv-primary">{title}</span>
      {detail && <span>{detail}</span>}
    </div>
  );
}

// MARK: - Health

/** Health: every check the server runs (or the open issues, or the alerts over time) with its Fix. */
export function ServerHealth({
  status,
  actions,
  strings,
  layout = PICKS.health,
}: SurfaceProps & { layout?: HealthLayout }) {
  const snapshot = status.snapshot;
  const props = { status, actions, strings };
  return (
    <div className="sv-surface" data-surface="health" data-layout={layout}>
      <header className="sv-health-head">
        <ServerIcon name="health" />
        <span className="sv-emphasis sv-primary">{strings.t("row.health")}</span>
        {snapshot && <span className="sv-tertiary">{snapshot.hostName}</span>}
      </header>
      {snapshot && layout === "checklist" && <HealthChecklist {...props} snapshot={snapshot} />}
      {snapshot && layout === "summary" && <HealthSummary {...props} snapshot={snapshot} />}
      {snapshot && layout === "timeline" && <HealthTimeline {...props} snapshot={snapshot} />}
      <Reject status={status} />
    </div>
  );
}

function HealthChecklist({ snapshot, status, actions, strings }: PanelProps) {
  return (
    <div className="sv-rows">
      {HealthOrdering.checklist(snapshot.checks, snapshot.alerts).map((row) => (
        <div key={row.check} className="sv-row" data-check={row.check} data-tall={row.alert ? "" : undefined}>
          <CheckGlyph severity={row.alert?.severity} />
          <span className="sv-stack sv-grow">
            <span data-dim={row.alert ? undefined : ""}>
              {checkName(strings, row.check, row.alert?.title ?? row.check)}
            </span>
            {row.alert && <span className="sv-caption sv-clamp">{row.alert.title}</span>}
          </span>
          {row.alert && <FixButton alert={row.alert} status={status} actions={actions} strings={strings} />}
        </div>
      ))}
    </div>
  );
}

function HealthSummary({ snapshot, status, actions, strings }: PanelProps) {
  const open = HealthOrdering.open(snapshot.alerts);
  const worst = HealthOrdering.worst(open);
  const calm = worst === undefined || worst === "info";
  return (
    <div className="sv-stack" data-gap="2">
      <div className="sv-summary-line">
        <Dot tone={calm ? "ok" : worst} large />
        <span>{calm ? strings.t("health.ok") : strings.t("status.attention")}</span>
      </div>
      {open.map((alert) => (
        <div key={`${alert.check}@${alert.raisedAt}`} className="sv-box sv-stack" data-alert={alert.check}>
          <span className="sv-split">
            <CheckGlyph severity={alert.severity} />
            <span className="sv-grow sv-emphasis">{alert.title}</span>
            <span className="sv-caption">{checkName(strings, alert.check, "")}</span>
          </span>
          <span className="sv-secondary sv-indent">{alert.body}</span>
          {alert.fix && (
            <span className="sv-end">
              <FixButton alert={alert} status={status} actions={actions} strings={strings} />
            </span>
          )}
        </div>
      ))}
    </div>
  );
}

function HealthTimeline({ snapshot, status, actions, strings }: PanelProps) {
  const events = HealthOrdering.timeline(snapshot.alerts);
  if (events.length === 0) return <p className="sv-secondary sv-empty">{strings.t("health.none")}</p>;
  return (
    <ol className="sv-timeline">
      {events.map((alert) => (
        <li key={`${alert.check}@${alert.raisedAt}`} className="sv-event" data-open={isOpen(alert) ? "" : undefined}>
          <span className="sv-event-time">{formatTime(alert.resolvedAt ?? alert.raisedAt, strings.language)}</span>
          <span className="sv-event-mark" data-tone={isOpen(alert) ? alert.severity : "ok"} />
          <span className="sv-stack">
            <span data-dim={isOpen(alert) ? undefined : ""}>{checkName(strings, alert.check, alert.title)}</span>
            <span className="sv-caption">{alert.title}</span>
            {alert.resolvedAt !== undefined ? (
              <span className="sv-caption" data-tone="ok">
                {`${strings.t("health.resolved")} · ${formatTime(alert.raisedAt, strings.language)}–${formatTime(alert.resolvedAt, strings.language)}`}
              </span>
            ) : (
              <span>
                <FixButton alert={alert} status={status} actions={actions} strings={strings} />
              </span>
            )}
          </span>
        </li>
      ))}
    </ol>
  );
}

// MARK: - Add Server

/** What the Add Server card asks of the app. */
export interface AddServerActions {
  setCode(code: string): void;
  setName(name: string): void;
  setTeam(team: string): void;
  setRunChief(on: boolean): void;
  /** Cancel or Deny: the draft goes and the card closes. */
  cancel(): void;
  /** Done: the card closes. */
  done(): void;
}

/** The Add Server card (palette "Add Server…", a pairing link): enter the code, check the server's
 * facts and four words, pick the team and name, Approve or Deny. One layout per step; every button
 * shows its key, and the click and the key run the same action. The fields keep what the person
 * types; a new opening (`approver.session`) starts them again from the app's draft. */
export function AddServerCard({
  status,
  actions,
  strings,
  words = PICKS.words,
  autoFocus = true,
  controlStandIn = false,
}: {
  status: ServerStatus;
  actions: AddServerActions;
  strings: Strings;
  words?: WordsLayout;
  autoFocus?: boolean;
  /** Draws Approve and Try Again in the card's footer (the gallery); in the app the panel's native footer does. */
  controlStandIn?: boolean;
}) {
  const approver = status.approver;
  const { step, candidate } = approver;
  const [code, setCode] = useState<string | null>(null);
  const [name, setName] = useState<string | null>(null);
  const field = useRef<HTMLInputElement>(null);
  const busy = step === "approving";
  const buttons = addServerButtons(approver);
  const shownName = name ?? approver.draft.name;

  // A new opening starts the fields from the app's draft, and the code field takes the keys.
  useEffect(() => {
    setCode(null);
    setName(null);
    if (autoFocus) field.current?.focus();
  }, [approver.session, autoFocus]);
  // A different server on the card: its own name, not one typed for the last.
  useEffect(() => setName(null), [candidate?.code]);

  const run = (action: AddServerAction) => {
    switch (action) {
      case "approve":
      case "retry":
        return; // The panel's native button (WebCardPanel's PersonControl), never the page.
      case "done":
        return actions.done();
      case "cancel":
        setCode(null);
        return actions.cancel();
    }
  };
  // Return presses the default button when it is on and not click-only (Done; never Approve or Try
  // Again); Escape is the card host's Cancel (host.ts), so the panel's own Escape and the page's run
  // the same way.
  const onReturn = useRef<(() => void) | null>(null);
  const main = buttonForKey(buttons, "Enter");
  onReturn.current = main ? () => run(main.action) : null;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || event.isComposing || event.defaultPrevented || !onReturn.current) return;
      event.preventDefault();
      onReturn.current();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="server-card sv-add" data-surface="add-server" data-step={step} data-layout={layoutOf(step)}>
      {step === "added" ? (
        <div className="sv-stack sv-center sv-added">
          <span data-tone="ok">
            <ServerIcon name="ok" size={32} />
          </span>
          <h2 className="server-card-title">{strings.format("approver.added", approver.added ?? "")}</h2>
          <span className="sv-secondary">{strings.t("approver.addedDetail")}</span>
        </div>
      ) : (
        <>
          <header className="sv-stack">
            <h2 className="server-card-title">{strings.t("approver.title")}</h2>
            <span className="sv-secondary">{strings.t("approver.subtitle")}</span>
          </header>
          <div className="sv-stack" data-gap="2">
            <input
              ref={field}
              className="sv-input sv-code-input"
              data-refused={step === "codeRefused" ? "" : undefined}
              value={code ?? approver.draft.code}
              placeholder="XXXX-XXXX"
              aria-label={strings.t("pairing.code")}
              spellCheck={false}
              autoComplete="off"
              autoCapitalize="characters"
              disabled={busy}
              onChange={(event) => {
                const next = PairingCode.editing(event.currentTarget.value);
                setCode(next);
                actions.setCode(next);
              }}
            />
            <CodeStatus step={step} reject={approver.reject} strings={strings} />
          </div>
          {candidate && showsCandidate(step) && (
            <fieldset className="sv-review" disabled={busy}>
              <Facts candidate={candidate} strings={strings} />
              <div className="sv-stack" data-gap="2">
                <span className="sv-emphasis">{strings.t("approver.wordsQuestion")}</span>
                <Words words={candidate.words} size="m" layout={words} />
                <span className="sv-caption">{strings.t("approver.wordsWarning")}</span>
              </div>
              <label className="sv-stack">
                <span className="sv-caption">{strings.t("approver.name")}</span>
                <input
                  className="sv-input"
                  aria-label={strings.t("approver.name")}
                  value={shownName}
                  placeholder={candidate.name}
                  onChange={(event) => {
                    setName(event.currentTarget.value);
                    actions.setName(event.currentTarget.value);
                  }}
                />
              </label>
              {/* One team needs no choice. */}
              {candidate.teams.length > 1 && (
                <div className="sv-stack">
                  <span className="sv-caption">{strings.t("approver.team")}</span>
                  <div className="sv-chips" role="radiogroup" aria-label={strings.t("approver.team")}>
                    {candidate.teams.map((team) => (
                      <label key={team.id} className="sv-chip">
                        <input
                          type="radio"
                          name="sv-team"
                          className="sv-chip-input"
                          aria-label={team.name}
                          checked={approver.draft.team === team.id}
                          onChange={() => actions.setTeam(team.id)}
                        />
                        {team.name}
                      </label>
                    ))}
                  </div>
                </div>
              )}
              <label className="sv-check">
                <input
                  type="checkbox"
                  aria-label={strings.t("approver.runChief")}
                  checked={approver.draft.runChief}
                  onChange={(event) => actions.setRunChief(event.currentTarget.checked)}
                />
                <span>{strings.t("approver.runChief")}</span>
              </label>
            </fieldset>
          )}
          {step === "approveFailed" && (
            <div className="sv-banner" role="alert">
              <ServerIcon name="warning" size={16} />
              <span>{approver.reject}</span>
            </div>
          )}
        </>
      )}
      <footer className="server-card-footer">
        {busy && <Spinner size={12} loading className="server-card-spinner" />}
        <span className="server-card-footer-gap" />
        {buttons
          // Approve and Try Again are the panel's native footer, never the page's (the gallery
          // draws them in their place).
          .filter((button) => controlStandIn || !isClickOnly(button.action))
          .map((button) => (
            <DialogButton
              key={button.isDefault ? "return" : "escape"}
              dialogKey={isClickOnly(button.action) ? null : button.isDefault ? "return" : "escape"}
              className={cx("server-card-button", button.isDefault && "is-default")}
              data-action={button.action}
              disabled={!button.enabled}
              onClick={isClickOnly(button.action) ? undefined : () => run(button.action)}
            >
              {strings.t(button.isDefault ? returnTitleKey(step) : escapeTitleKey(step))}
            </DialogButton>
          ))}
      </footer>
    </div>
  );
}

function CodeStatus({ step, reject, strings }: { step: string; reject?: string; strings: Strings }) {
  switch (step) {
    case "lookingUp":
      return (
        <span className="sv-split sv-secondary">
          <Spinner size={12} loading className="server-card-spinner" />
          {strings.t("approver.lookingUp")}
        </span>
      );
    case "codeRefused":
      return (
        <span className="sv-stack" role="alert">
          <span data-tone="critical">{reject}</span>
          <span className="sv-caption">{strings.t("approver.expiryHint")}</span>
        </span>
      );
    case "enterCode":
      return <span className="sv-caption">{strings.t("approver.codeHint")}</span>;
    default:
      return null;
  }
}

function Facts({ candidate, strings }: { candidate: PairingCandidate; strings: Strings }) {
  const parts = [candidate.os, candidate.version];
  if (candidate.region) parts.push(regionName(candidate.region, strings.language));
  return (
    <div className="sv-box sv-split">
      <ServerIcon name="server" size={20} className="sv-secondary" />
      <span className="sv-stack">
        <span className="sv-emphasis">{candidate.name}</span>
        <span className="sv-caption sv-clamp">{parts.join(" · ")}</span>
      </span>
    </div>
  );
}
