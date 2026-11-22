// l10n-allow-file: gallery design fixtures for the native browser omnibar and tab strip, not shipped UI.
// Leo, 2026-11-21: browse the web on the VMs, "offload our ... web browsing, our ... RAM usage, our CPU usage,
// all of that onto the VMs themselves. That's the feature". Spec: docs/remote-browser-machine-picker.md.
//
// The native Swift browser (AddressBarView, MachineBadgeView, the tab strip) draws the pick; this file only
// picks its look. It has no logic: every fact (machine, state, round trip, memory) is a prop from the gallery
// fixture, as the Rust rb/1 stats and MachineBrowserState will hand it to Swift.
//   chip: the omnibar's machine chip names the machine with a latency dot; its menu is the picker.
//   line: a colored underline on the tab and a leading machine segment in the omnibar (containers).
//   bar:  a slim connection bar under the omnibar (remote desktop), with Move to This Mac.
import type { ReactNode } from "react";
import "./RemoteBrowserDesigns.css";

export type RemoteBrowserDesign = "chip" | "line" | "bar";
/** live: frames arrive; slow: over 150 ms; paused: no link, last frame kept; starting: the host starts. */
export type RemoteTabState = "local" | "starting" | "live" | "slow" | "paused";
export type LinkQuality = "good" | "fair" | "poor";

export interface PickerMachine {
  id: string;
  name: string;
  /** The machine's tab color (MachineRegistry.tabColorName), a CSS color. */
  color: string;
  /** "Cloud", "Linux", "Mac": the secondary line. */
  kind: string;
  /** Round trip in ms; absent when not connected. */
  rttMs?: number;
  quality?: LinkQuality;
  /** Why it cannot run a browser now (asleep wakes on use, not installed). */
  note?: string;
  disabled?: boolean;
}

export interface RemoteBrowserDesignsProps {
  design: RemoteBrowserDesign;
  state: RemoteTabState;
  /** The machine the active tab runs on (ignored for local). */
  machine: PickerMachine;
  /** Every machine for the picker, This Mac first is implied. */
  machines: PickerMachine[];
  url: string;
  pageTitle: string;
  menuOpen?: boolean;
  /** What this Mac and the machine pay for the tab, preformatted ("28 MB"). */
  macMemory?: string;
  machineMemory?: string;
  machineCpu?: string;
}

function Icon({ d, size = 14 }: { d: string; size?: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} aria-hidden className="rbd-icon">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

const BACK = "M10 3 5 8l5 5";
const FORWARD = "M6 3l5 5-5 5";
const RELOAD = "M13 8a5 5 0 1 1-1.5-3.5M13 2.5V5h-2.5";
const LOCK = "M4.5 7.5h7v5.5h-7zM6 7.5V5.5a2 2 0 0 1 4 0v2";
const CHEVRON = "M4.5 6.5 8 10l3.5-3.5";
const CHECK = "M3.5 8.5 6.5 11.5 12.5 4.5";
const LAPTOP = "M3 4h10v6.5H3zM1.5 12.5h13";
const CLOUD = "M4.5 12.5a3 3 0 0 1-.4-6 4 4 0 0 1 7.6-1A3 3 0 0 1 11.5 12.5z";

function Dot({ quality, state }: { quality?: LinkQuality; state: RemoteTabState }) {
  const level = state === "paused" ? "poor" : state === "starting" ? "wait" : (quality ?? "good");
  return <span className="rbd-dot" data-level={level} aria-hidden />;
}

function Bars({ quality, state }: { quality?: LinkQuality; state: RemoteTabState }) {
  const lit = state === "paused" ? 0 : state === "starting" ? 1 : quality === "poor" ? 1 : quality === "fair" ? 2 : 3;
  const level = state === "paused" || quality === "poor" ? "poor" : quality === "fair" ? "fair" : "good";
  return (
    <span className="rbd-bars" data-level={level} aria-hidden>
      {[0, 1, 2].map((index) => (
        <i key={index} data-on={index < lit || undefined} style={{ height: 4 + index * 3 }} />
      ))}
    </span>
  );
}

function stateText(props: RemoteBrowserDesignsProps): string {
  const { state, machine } = props;
  if (state === "starting") return `Starting the browser on ${machine.name}...`;
  if (state === "paused") return `${machine.name} unreachable`;
  return `${machine.rttMs ?? 0} ms`;
}

function TabStrip(props: RemoteBrowserDesignsProps) {
  const remote = props.state !== "local";
  return (
    <div className="rbd-tabs">
      <div className="rbd-tab">
        <span className="rbd-favicon" />
        <span className="rbd-tab-title">Docs</span>
      </div>
      <div
        className="rbd-tab"
        data-active
        data-remote={remote || undefined}
        data-design={props.design}
        style={{ ["--rbd-machine" as string]: props.machine.color }}
        title={remote ? `Runs on ${props.machine.name}` : undefined}
      >
        {remote && props.design === "chip" ? <span className="rbd-tab-lead" /> : null}
        <span className="rbd-favicon" data-dim={props.state === "paused" || undefined} />
        <span className="rbd-tab-title">{props.pageTitle}</span>
        {remote && props.design === "line" ? <span className="rbd-tab-line" /> : null}
      </div>
      <div className="rbd-tab">
        <span className="rbd-favicon" />
        <span className="rbd-tab-title">Pull requests</span>
      </div>
    </div>
  );
}

function MachineIcon({ kind }: { kind: string }) {
  return <Icon d={kind === "Cloud" ? CLOUD : LAPTOP} size={14} />;
}

function PickerMenu(props: RemoteBrowserDesignsProps) {
  const current = props.state === "local" ? "local" : props.machine.id;
  const row = (id: string, name: string, kind: string, trail: ReactNode, color?: string, disabled?: boolean) => (
    <div
      className="rbd-menu-row"
      data-current={id === current || undefined}
      data-disabled={disabled || undefined}
      key={id}
    >
      <span className="rbd-menu-check">{id === current ? <Icon d={CHECK} size={12} /> : null}</span>
      <span className="rbd-menu-icon" style={color ? { color } : undefined}>
        <MachineIcon kind={kind} />
      </span>
      <span className="rbd-menu-name">
        {name}
        <span className="rbd-menu-kind">{kind}</span>
      </span>
      <span className="rbd-menu-trail">{trail}</span>
    </div>
  );
  return (
    <div className="rbd-menu" role="menu" data-design={props.design}>
      <div className="rbd-menu-head">Run this tab on</div>
      {row("local", "This Mac", "Mac", <span className="rbd-menu-note">this Mac's RAM and CPU</span>)}
      {props.machines.map((machine) =>
        row(
          machine.id,
          machine.name,
          machine.kind,
          machine.note ? (
            <span className="rbd-menu-note">{machine.note}</span>
          ) : (
            <span className="rbd-menu-ms">
              <Dot quality={machine.quality} state="live" />
              {machine.rttMs} ms
            </span>
          ),
          machine.color,
          machine.disabled,
        ),
      )}
      {props.state !== "local" && props.macMemory ? (
        <>
          <div className="rbd-menu-sep" />
          <div className="rbd-menu-cost">
            <div>
              <span>This Mac</span>
              <b>{props.macMemory}</b>
              <em>video decode only</em>
            </div>
            <div>
              <span>{props.machine.name}</span>
              <b>{props.machineMemory}</b>
              <em>{props.machineCpu} CPU</em>
            </div>
          </div>
        </>
      ) : null}
      <div className="rbd-menu-sep" />
      <div className="rbd-menu-row rbd-menu-action">
        <span className="rbd-menu-check" />
        <span className="rbd-menu-name">Machines settings...</span>
      </div>
    </div>
  );
}

function Omnibar(props: RemoteBrowserDesignsProps) {
  const remote = props.state !== "local";
  const { design, machine } = props;
  return (
    <div className="rbd-toolbar">
      <span className="rbd-nav">
        <Icon d={BACK} />
      </span>
      <span className="rbd-nav" data-off>
        <Icon d={FORWARD} />
      </span>
      <span className="rbd-nav">
        <Icon d={RELOAD} />
      </span>
      <div className="rbd-omnibar" data-design={design}>
        {design === "line" ? (
          <span
            className="rbd-segment"
            data-remote={remote || undefined}
            data-open={props.menuOpen || undefined}
            style={{ ["--rbd-machine" as string]: machine.color }}
          >
            {remote ? machine.name : "This Mac"}
            <Icon d={CHEVRON} size={10} />
          </span>
        ) : null}
        <span className="rbd-lock">
          <Icon d={LOCK} size={12} />
        </span>
        <span className="rbd-url">{props.url}</span>
        {design === "line" && remote ? (
          <span className="rbd-latency" data-state={props.state}>
            <Dot quality={machine.quality} state={props.state} />
            {stateText(props)}
          </span>
        ) : null}
        {design === "chip" ? (
          <span
            className="rbd-chip"
            data-remote={remote || undefined}
            data-open={props.menuOpen || undefined}
            title={remote ? `Runs on ${machine.name}, ${stateText(props)}` : "Runs on this Mac"}
          >
            {remote ? <Dot quality={machine.quality} state={props.state} /> : null}
            {remote ? machine.name : "This Mac"}
            <Icon d={CHEVRON} size={10} />
          </span>
        ) : null}
        {design === "bar" ? (
          <span className="rbd-chip" data-open={props.menuOpen || undefined}>
            {remote ? machine.name : "This Mac"}
            <Icon d={CHEVRON} size={10} />
          </span>
        ) : null}
      </div>
    </div>
  );
}

function ConnectionBar(props: RemoteBrowserDesignsProps) {
  const { machine, state } = props;
  if (state === "local") return null;
  return (
    <div className="rbd-connbar" data-state={state} style={{ ["--rbd-machine" as string]: machine.color }}>
      <span className="rbd-connbar-icon">
        <MachineIcon kind={machine.kind} />
      </span>
      <span className="rbd-connbar-name">Running on {machine.name}</span>
      <Bars quality={machine.quality} state={state} />
      <span className="rbd-connbar-fact">{stateText(props)}</span>
      {state === "live" || state === "slow" ? (
        <span className="rbd-connbar-fact">
          This Mac {props.macMemory} &middot; {machine.name} {props.machineMemory}
        </span>
      ) : null}
      <span className="rbd-connbar-spacer" />
      <span className="rbd-connbar-button">Move to This Mac</span>
    </div>
  );
}

function Page(props: RemoteBrowserDesignsProps) {
  return (
    <div className="rbd-page" data-state={props.state}>
      <div className="rbd-site">
        <div className="rbd-site-nav">
          <span className="rbd-site-logo" />
          <span className="rbd-site-link" />
          <span className="rbd-site-link" />
          <span className="rbd-site-link" />
        </div>
        <div className="rbd-site-hero" />
        <div className="rbd-site-title">{props.pageTitle}</div>
        {[92, 84, 88, 60, 90, 76].map((width, index) => (
          <div key={index} className="rbd-site-line" style={{ width: `${width}%` }} />
        ))}
      </div>
      {props.state === "starting" ? (
        <div className="rbd-overlay">
          <div className="rbd-spinner" />
          <div className="rbd-overlay-title">Starting the browser on {props.machine.name}</div>
          <div className="rbd-overlay-detail">{props.url} opens when it is ready</div>
        </div>
      ) : null}
      {props.state === "paused" ? (
        <div className="rbd-overlay" data-paused>
          <div className="rbd-overlay-title">{props.machine.name} is unreachable</div>
          <div className="rbd-overlay-detail">The page stays as it was. Its cookies are on {props.machine.name}.</div>
          <div className="rbd-overlay-buttons">
            <span className="rbd-button" data-default>
              Reconnect
            </span>
            <span className="rbd-button">Open on This Mac</span>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export function RemoteBrowserDesigns(props: RemoteBrowserDesignsProps) {
  return (
    <div className="rbd-pane" data-design={props.design}>
      <TabStrip {...props} />
      <Omnibar {...props} />
      {props.design === "bar" ? <ConnectionBar {...props} /> : null}
      <Page {...props} />
      {props.menuOpen ? <PickerMenu {...props} /> : null}
    </div>
  );
}
