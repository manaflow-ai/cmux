// l10n-allow-file: gallery design mock of the native sidebar footer, not shipped UI.
// Four designs of the AutoCloud status icon at the bottom left of the NEXT sidebar (Leo, 2026-11-24:
// "honestly there's something incredibly google docs-y about this. discord-y. ... i think there's even
// situations where we can have an icon maybe toggle somewhere omnipresent... say the bottom left of the
// sidebar area, which is currently not used for anything. because we hid spaces by default").
// The native footer is AppKit (SidebarFooterBand.swift), so this is the design reference the way
// AllChatsDesigns is: the chosen design is built there. What each state says (headline, tone, counts)
// is decided in Rust (`cmux-autocloud-status`); this file only draws it, from the same fixtures file the
// Rust test reads.
import { useState } from "react";
import "./AutoCloudStatus.css";
import fixtures from "./autocloudStatus.fixtures.json";
import { AUTO_CLOUD_MATRIX_DESIGNS, AUTO_CLOUD_MATRIX_STATES } from "./autocloudStatusMatrix";

export type AutoCloudDesign = "glyph" | "pill" | "split" | "strip";
export type Headline = "off" | "offline" | "syncing" | "warming" | "ready" | "active";
type Tone = "quiet" | "working" | "attention";
type Sync = { state: "synced" } | { state: "syncing"; changes: number } | { state: "offline"; pending: number };
export interface Here {
  name: string;
  kind: "person" | "agent";
  at: "mac" | "cloud" | "phone";
}
/** The Rust `AutoCloudStatus` (cmux-autocloud-status), as its serde JSON. */
export interface AutoCloudStatus {
  cloud: "off" | "warming" | "ready" | "active";
  sync: Sync;
  here: Here[];
}
interface Fixture {
  id: string;
  note: string;
  status: AutoCloudStatus;
  expect: { headline: Headline; tone: Tone; pending: number; people: number; agents: number };
}

const all = fixtures as Fixture[];
const byId = (id: string): Fixture => all.find((f) => f.id === id) ?? all[0];

export interface AutoCloudStatusProps {
  design: AutoCloudDesign;
  /** A state from autocloudStatus.fixtures.json. */
  state: string;
  /** Spaces turned on: the dots strip shows in the footer too. */
  spaces?: boolean;
  /** The popover starts open. */
  open?: boolean;
  /** Show the state picker under the sidebar (the walk-through). */
  simulate?: boolean;
  /** Only the footer row (the matrix's cells). */
  footerOnly?: boolean;
}

const cloudPath = "M4.6 12.4h6.1a3 3 0 0 0 .6-5.94A4.1 4.1 0 0 0 3.6 7.9a2.3 2.3 0 0 0 1 4.5Z";

function Glyph({ headline }: { headline: Headline }) {
  return (
    <svg className="acs-glyph" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path d={cloudPath} fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
      {headline === "off" && (
        <path d="M2.6 2.6l10.8 10.8" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      )}
    </svg>
  );
}

function hue(name: string): number {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) % 360;
  return h;
}

function Avatar({ who }: { who: Here }) {
  return (
    <span
      className="acs-avatar"
      data-kind={who.kind}
      style={{ "--acs-hue": hue(who.name) } as React.CSSProperties}
      title={who.name}
    >
      {who.kind === "agent" ? "✳" : who.name[0]}
    </span>
  );
}

/** First `max` avatars, people first (the Rust `avatars`), and the overflow. */
function avatars(here: Here[], max: number): [Here[], number] {
  const sorted = [...here].sort((a, b) => Number(a.kind !== "person") - Number(b.kind !== "person"));
  return [sorted.slice(0, max), Math.max(0, sorted.length - max)];
}

function Stack({ here, max = 3 }: { here: Here[]; max?: number }) {
  const [shown, rest] = avatars(here, max);
  return (
    <span className="acs-stack">
      {shown.map((w) => (
        <Avatar key={w.name} who={w} />
      ))}
      {rest > 0 && <span className="acs-more">+{rest}</span>}
    </span>
  );
}

function label(f: Fixture): { title: string; detail: string } {
  const s = f.status;
  switch (f.expect.headline) {
    case "off":
      return { title: "AutoCloud is off", detail: "Chats stay on this Mac." };
    case "offline":
      return {
        title: `Offline, ${f.expect.pending} queued`,
        detail: "Edits are saved here and merge without conflicts when you are back.",
      };
    case "syncing":
      return {
        title: `Syncing ${f.expect.pending} change${f.expect.pending === 1 ? "" : "s"}`,
        detail: "Mac and cloud are catching up.",
      };
    case "warming":
      return { title: "Cloud warming up", detail: "Your chat runs here now; nothing waits for the cloud." };
    case "active":
      return { title: "Working in the cloud", detail: "An agent is running on your cloud machine." };
    default:
      return { title: "Synced", detail: s.cloud === "ready" ? "Cloud machine ready." : "Everything is up to date." };
  }
}

/** The glyph with its status ring and badge. `badge`: draw the count. */
function Mark({ f, badge }: { f: Fixture; badge: boolean }) {
  const h = f.expect.headline;
  const n = f.expect.pending > 0 ? f.expect.pending : f.expect.people + f.expect.agents;
  return (
    <span className="acs-mark" data-headline={h} data-tone={f.expect.tone}>
      <svg className="acs-ring" viewBox="0 0 28 28" width="28" height="28" aria-hidden="true">
        <circle cx="14" cy="14" r="12" fill="none" strokeWidth="1.5" />
      </svg>
      <Glyph headline={h} />
      {(h === "ready" || h === "active") && <i className="acs-dot" />}
      {badge && n > 0 && (
        <b className="acs-badge" data-kind={f.expect.pending > 0 ? "pending" : "here"}>
          {n > 99 ? "99+" : n}
        </b>
      )}
    </span>
  );
}

function Popover({ f, onToggle, enabled }: { f: Fixture; onToggle: () => void; enabled: boolean }) {
  const s = f.status;
  const text = label(f);
  const cloudLine =
    s.cloud === "off"
      ? "Off"
      : s.cloud === "warming"
        ? "Warming up (about a minute)"
        : s.cloud === "active"
          ? "Working"
          : "Ready";
  const syncLine =
    s.sync.state === "synced"
      ? "Everything synced"
      : s.sync.state === "syncing"
        ? `Syncing ${s.sync.changes} change${s.sync.changes === 1 ? "" : "s"}`
        : `Offline, ${s.sync.pending} edit${s.sync.pending === 1 ? "" : "s"} queued`;
  return (
    <div className="acs-popover" role="dialog" aria-label="AutoCloud">
      <header className="acs-pop-head">
        <span className="acs-pop-title">AutoCloud</span>
        <button type="button" role="switch" aria-checked={enabled} className="acs-switch" onClick={onToggle}>
          <i />
        </button>
      </header>
      <p className="acs-pop-lede">
        {enabled ? text.detail : "Turn on to start every chat instantly and warm a cloud machine behind it."}
      </p>
      {enabled && (
        <dl className="acs-pop-rows">
          <dt>Cloud</dt>
          <dd>{cloudLine}</dd>
          <dt>Sync</dt>
          <dd data-tone={f.expect.tone}>{syncLine}</dd>
        </dl>
      )}
      {enabled && (
        <section className="acs-pop-here">
          <h4>Here{s.here.length > 0 ? ` (${s.here.length})` : ""}</h4>
          {s.here.length === 0 ? (
            <p className="acs-pop-empty">Only you.</p>
          ) : (
            <ul>
              {s.here.map((w) => (
                <li key={w.name}>
                  <Avatar who={w} />
                  <span className="acs-who">{w.name}</span>
                  <span className="acs-at">
                    {w.at === "cloud" ? "Cloud" : w.at === "phone" ? "iPhone" : "Another Mac"}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
      <footer className="acs-pop-foot">
        <span>Open cloud chat</span>
        <span>AutoCloud settings</span>
      </footer>
    </div>
  );
}

/** The footer row of the mock sidebar: account avatar, our icon, the spaces dots, Search. */
function Footer({
  design,
  f,
  spaces,
  open,
  toggleOpen,
  enabled,
  onToggleEnabled,
}: {
  design: AutoCloudDesign;
  f: Fixture;
  spaces: boolean;
  open: boolean;
  toggleOpen: () => void;
  enabled: boolean;
  onToggleEnabled: () => void;
}) {
  const t = label(f);
  const here = f.status.here;
  const slot = (() => {
    switch (design) {
      case "glyph":
        return (
          <button
            type="button"
            className="acs-btn"
            aria-label={t.title}
            title={t.title}
            onClick={toggleOpen}
            data-open={open || undefined}
          >
            <Mark f={f} badge />
          </button>
        );
      case "pill":
        return (
          <button
            type="button"
            className="acs-pill"
            aria-label={t.title}
            title={t.title}
            onClick={toggleOpen}
            data-open={open || undefined}
            data-tone={f.expect.tone}
            data-headline={f.expect.headline}
          >
            <span className="acs-pill-dot" />
            {here.length > 0 ? <Stack here={here} max={3} /> : <Glyph headline={f.expect.headline} />}
            {f.expect.pending > 0 && <span className="acs-pill-count">{f.expect.pending}</span>}
          </button>
        );
      case "split":
        return (
          <span className="acs-split">
            <button
              type="button"
              className="acs-btn"
              aria-pressed={enabled}
              aria-label={enabled ? "Turn AutoCloud off" : "Turn AutoCloud on"}
              title={enabled ? `${t.title}. Click to turn off` : "Turn AutoCloud on"}
              onClick={onToggleEnabled}
            >
              <Mark f={f} badge={false} />
            </button>
            {enabled && here.length > 0 && (
              <button
                type="button"
                className="acs-people"
                aria-label={`${here.length} here`}
                onClick={toggleOpen}
                data-open={open || undefined}
              >
                <Stack here={here} max={3} />
              </button>
            )}
            {enabled && f.expect.pending > 0 && (
              <span className="acs-split-count" data-tone={f.expect.tone}>
                {f.expect.pending}
              </span>
            )}
          </span>
        );
      case "strip":
        return (
          <button
            type="button"
            className="acs-btn"
            aria-label={t.title}
            title={t.title}
            onClick={toggleOpen}
            data-open={open || undefined}
          >
            <Mark f={f} badge={false} />
          </button>
        );
    }
  })();
  return (
    <div className="acs-footer">
      <span className="acs-account">L</span>
      <span className="acs-slot">{slot}</span>
      {spaces && (
        <span className="acs-spaces" aria-label="Spaces">
          <i data-on /> <i /> <i />
        </span>
      )}
      <span className="acs-spacer" />
      <svg className="acs-search" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <path
          d="M7 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm3.5-1.5L14 14"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
        />
      </svg>
    </div>
  );
}

/** Discord's voice bar: only a state that is not calm raises a strip over the footer. */
function Strip({ f, onClick }: { f: Fixture; onClick: () => void }) {
  const t = label(f);
  if (f.expect.tone === "quiet" && f.status.here.length === 0) return null;
  return (
    <button
      type="button"
      className="acs-strip"
      data-tone={f.expect.tone}
      data-headline={f.expect.headline}
      onClick={onClick}
    >
      <span className="acs-strip-mark">
        <Mark f={f} badge={false} />
      </span>
      <span className="acs-strip-text">
        <b>{f.expect.tone === "quiet" ? `${f.status.here.length} here` : t.title}</b>
        <small>{f.expect.tone === "quiet" ? f.status.here.map((w) => w.name).join(", ") : t.detail}</small>
      </span>
      {f.status.here.length > 0 && <Stack here={f.status.here} max={2} />}
    </button>
  );
}

export function AutoCloudStatusDesigns({
  design,
  state,
  spaces = false,
  open = false,
  simulate = false,
  footerOnly = false,
}: AutoCloudStatusProps) {
  const [current, setCurrent] = useState(state);
  const [isOpen, setOpen] = useState(open);
  const [enabled, setEnabled] = useState(byId(state).status.cloud !== "off");
  const picked = byId(current);
  // AutoCloud off shows the off state whatever the feed says; turned on from off, it starts from synced.
  const shown: Fixture = enabled ? (picked.status.cloud === "off" ? byId("synced") : picked) : byId("off");
  const toggleEnabled = () => setEnabled((v) => !v);
  return (
    <div className="acs-root" data-design={design}>
      <div className="acs-sidebar" data-footer-only={footerOnly || undefined}>
        {!footerOnly && (
          <div className="acs-rows" aria-hidden="true">
            <span className="acs-row" data-on />
            <span className="acs-row" />
            <span className="acs-row" />
            <span className="acs-row" />
            <span className="acs-row short" />
          </div>
        )}
        {design === "strip" && <Strip f={shown} onClick={() => setOpen((v) => !v)} />}
        <Footer
          design={design}
          f={shown}
          spaces={spaces}
          open={isOpen}
          toggleOpen={() => setOpen((v) => !v)}
          enabled={enabled}
          onToggleEnabled={toggleEnabled}
        />
        {isOpen && <Popover f={shown} enabled={enabled} onToggle={toggleEnabled} />}
      </div>
      {simulate && (
        <div className="acs-sim" role="group" aria-label="Simulate a state">
          {all.map((x) => (
            <button
              key={x.id}
              type="button"
              data-on={x.id === current || undefined}
              onClick={() => {
                setCurrent(x.id);
                setEnabled(x.status.cloud !== "off");
              }}
            >
              {x.id}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

const matrixStates = AUTO_CLOUD_MATRIX_STATES;
const designNames: Record<AutoCloudDesign, string> = {
  glyph: "A  Glyph + ring + badge",
  pill: "B  Pill",
  split: "C  Two slots",
  strip: "D  Strip (Discord)",
};

/** Every design in every state, footers only, for one look at the whole set. */
export interface AutoCloudStatusMatrixProps {
  spaces?: boolean;
}

export function AutoCloudMatrix({ spaces = false }: AutoCloudStatusMatrixProps) {
  return (
    <div className="acs-matrix">
      <span />
      {(AUTO_CLOUD_MATRIX_DESIGNS as readonly AutoCloudDesign[]).map((d) => (
        <b key={d}>{designNames[d]}</b>
      ))}
      {matrixStates.map((id) => (
        <div className="acs-matrix-row" key={id}>
          <span className="acs-matrix-label">{id}</span>
          {(AUTO_CLOUD_MATRIX_DESIGNS as readonly AutoCloudDesign[]).map((d) => (
            <AutoCloudStatusDesigns key={d} design={d} state={id} spaces={spaces} footerOnly />
          ))}
        </div>
      ))}
    </div>
  );
}
