// l10n-allow-file: a proposal drawn only in the gallery (pages.customize-studio) until Leo picks one
// of its three layouts; the picked one moves its words into the string catalog when it ships.
// The customization paradigm (cmuxterm-hq docs/design/customization-paradigm.md): discover, preview,
// try, keep and share customizations, and try Leo's setup in one click. Every layout draws the same
// live preview, a small cmux window whose classes are the customizations that are on, so flipping a
// switch shows its effect at once, and each customization's before/after is that window without and
// with it.
import { useState } from "react";
import {
  CUSTOMIZATIONS,
  SETUPS,
  byId,
  diff,
  liveConflicts,
  sourceLabel,
  type Customization,
  type Effect,
  type Setup,
} from "./customizeStudio";

export type StudioLayout = "store" | "manager" | "setups";

/** A small cmux window: a sidebar of sessions, a chat with two messages and a composer. */
export function MiniCmux({ on, size = "large" }: { on: ReadonlySet<Effect>; size?: "large" | "thumb" }) {
  const classes = ["mini-cmux", `mini-cmux-${size}`, ...[...on].map((effect) => `fx-${effect}`)];
  return (
    <div className={classes.join(" ")} aria-hidden="true">
      <div className="mini-sidebar">
        <span className="mini-row mini-row-on" />
        <span className="mini-row" />
        <span className="mini-row" />
        <span className="mini-row" />
        {on.has("standup") && <span className="mini-chip">3 PRs in build</span>}
      </div>
      <div className="mini-main">
        <div className="mini-titlebar" />
        {on.has("yours") && <div className="mini-welcome">Make cmux yours</div>}
        <div className="mini-chat">
          <span className="mini-bubble" />
          <span className="mini-bubble mini-bubble-mine" />
          <span className="mini-bubble mini-bubble-new" />
        </div>
        <div className="mini-composer" />
      </div>
    </div>
  );
}

/** One customization's before and after: the live window without it and with it. */
function BeforeAfter({ base, id }: { base: ReadonlySet<Effect>; id: Effect }) {
  const without = new Set(base);
  without.delete(id);
  const withIt = new Set(base);
  withIt.add(id);
  return (
    <div className="studio-before-after">
      <figure>
        <MiniCmux on={without} size="thumb" />
        <figcaption>Before</figcaption>
      </figure>
      <figure>
        <MiniCmux on={withIt} size="thumb" />
        <figcaption>After</figcaption>
      </figure>
    </div>
  );
}

function Switch({ on, label, onChange }: { on: boolean; label: string; onChange: (next: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className={on ? "studio-switch studio-switch-on" : "studio-switch"}
      onClick={() => onChange(!on)}
    />
  );
}

function SourcePill({ item }: { item: Customization }) {
  const pending = item.source.kind === "pr" && !item.source.merged;
  return (
    <span className={pending ? "studio-pill studio-pill-pending" : "studio-pill"}>{sourceLabel(item.source)}</span>
  );
}

/** The bar a trial shows: what is being tried, and Keep or Revert (the macOS display-change pattern). */
function TrialBar({ setup, onKeep, onRevert }: { setup: Setup; onKeep: () => void; onRevert: () => void }) {
  return (
    <div className="studio-trial" role="status">
      <span>
        Trying <strong>{setup.name}</strong>. It reverts when you quit unless you keep it.
      </span>
      <button type="button" className="studio-button" onClick={onRevert}>
        Revert
      </button>
      <button type="button" className="studio-button studio-button-primary" onClick={onKeep}>
        Keep
      </button>
    </div>
  );
}

type StudioState = {
  on: Set<Effect>;
  kept: Set<Effect>;
  trying: Setup | null;
};

function useStudio(initial: { on: readonly Effect[]; trying?: string }) {
  const start = new Set(initial.on);
  const trying = SETUPS.find((setup) => setup.id === initial.trying) ?? null;
  const [state, setState] = useState<StudioState>({
    on: trying ? new Set(trying.on) : start,
    kept: start,
    trying,
  });
  return {
    ...state,
    toggle: (id: Effect, next: boolean) =>
      setState((before) => {
        const on = new Set(before.on);
        if (next) on.add(id);
        else on.delete(id);
        return { ...before, on, kept: before.trying ? before.kept : on };
      }),
    tryOn: (setup: Setup) => setState((before) => ({ ...before, on: new Set(setup.on), trying: setup })),
    keep: () => setState((before) => ({ ...before, kept: before.on, trying: null })),
    revert: () => setState((before) => ({ ...before, on: before.kept, trying: null })),
  };
}

type Studio = ReturnType<typeof useStudio>;

/** Store: a shelf of setups and a grid of customizations, each a card with its after picture; the
 * selected one opens on the right with its before/after and one switch (Raycast Store, Obsidian
 * community plugins). */
function StoreLayout({ studio, selected: initialSelected }: { studio: Studio; selected: Effect }) {
  const [selected, setSelected] = useState<Effect>(initialSelected);
  const item = byId(selected);
  return (
    <div className="studio-store">
      <div className="studio-store-browse">
        <div className="studio-setups-shelf">
          {SETUPS.filter((setup) => setup.id !== "default").map((setup) => (
            <div key={setup.id} className="studio-setup-card" data-setup={setup.id}>
              <MiniCmux on={new Set(setup.on)} size="thumb" />
              <div className="studio-setup-text">
                <strong>{setup.name}</strong>
                <span>{setup.line}</span>
              </div>
              <button type="button" className="studio-button studio-button-primary" onClick={() => studio.tryOn(setup)}>
                Try
              </button>
            </div>
          ))}
        </div>
        <div className="studio-grid">
          {CUSTOMIZATIONS.map((entry) => (
            <button
              key={entry.id}
              type="button"
              className={entry.id === selected ? "studio-card studio-card-selected" : "studio-card"}
              data-customization={entry.id}
              onClick={() => setSelected(entry.id)}
            >
              <MiniCmux on={new Set([entry.id])} size="thumb" />
              <span className="studio-card-name">
                {entry.name}
                {studio.on.has(entry.id) && <span className="studio-on-dot" aria-label="On" />}
              </span>
              <span className="studio-card-line">{entry.line}</span>
            </button>
          ))}
        </div>
      </div>
      <aside className="studio-detail">
        <div className="studio-detail-head">
          <div>
            <h3>{item.name}</h3>
            <span className="studio-muted">
              by {item.author} · <SourcePill item={item} />
            </span>
          </div>
          <Switch on={studio.on.has(item.id)} label={item.name} onChange={(next) => studio.toggle(item.id, next)} />
        </div>
        <p>{item.line}</p>
        <BeforeAfter base={studio.on} id={item.id} />
        <h4>Live</h4>
        <MiniCmux on={studio.on} />
      </aside>
    </div>
  );
}

/** Manager: a mod manager's list, one switch per customization with its source and any conflict, and
 * the live window beside it; a setup picker on top swaps the whole list (VS Code profiles, game mod
 * managers' load order and conflict lines). */
function ManagerLayout({ studio }: { studio: Studio }) {
  const conflicts = liveConflicts(studio.on);
  const [peek, setPeek] = useState<Effect | null>(null);
  return (
    <div className="studio-manager">
      <div className="studio-manager-list">
        <div className="studio-manager-head">
          <span className="studio-muted">Setup</span>
          {SETUPS.map((setup) => (
            <button
              key={setup.id}
              type="button"
              className="studio-segment"
              data-setup={setup.id}
              aria-pressed={studio.trying?.id === setup.id}
              onClick={() => studio.tryOn(setup)}
            >
              {setup.name}
            </button>
          ))}
        </div>
        <ul>
          {CUSTOMIZATIONS.map((item) => {
            const lost = conflicts.find((conflict) => conflict.loser === item.id);
            return (
              <li
                key={item.id}
                data-customization={item.id}
                onMouseEnter={() => setPeek(item.id)}
                onMouseLeave={() => setPeek(null)}
              >
                <div className="studio-manager-text">
                  <span className="studio-card-name">
                    {item.name} <SourcePill item={item} />
                  </span>
                  <span className="studio-card-line">
                    {lost ? `${byId(lost.winner).name} wins: both set the sidebar.` : item.line}
                  </span>
                </div>
                <Switch
                  on={studio.on.has(item.id)}
                  label={item.name}
                  onChange={(next) => studio.toggle(item.id, next)}
                />
              </li>
            );
          })}
        </ul>
      </div>
      <div className="studio-manager-preview">
        <MiniCmux on={studio.on} />
        {peek ? (
          <BeforeAfter base={studio.on} id={peek} />
        ) : (
          <p className="studio-muted">Point at a row to see its before and after.</p>
        )}
      </div>
    </div>
  );
}

/** Setups: people first. Pick whose setup to look at; it lists what it would change from yours, each
 * line a switch, over the live window of the result (Arc's spaces, VS Code's profile import). */
function SetupsLayout({ studio, initialSetup }: { studio: Studio; initialSetup: string }) {
  const [picked, setPicked] = useState(SETUPS.find((setup) => setup.id === initialSetup) ?? SETUPS[1]!);
  const changes = diff(studio.kept, picked);
  return (
    <div className="studio-setups">
      <div className="studio-setups-people">
        {SETUPS.map((setup) => (
          <button
            key={setup.id}
            type="button"
            data-setup={setup.id}
            className={setup.id === picked.id ? "studio-person studio-person-picked" : "studio-person"}
            onClick={() => setPicked(setup)}
          >
            <MiniCmux on={new Set(setup.on)} size="thumb" />
            <strong>{setup.name}</strong>
            <span className="studio-muted">{setup.on.length} customizations</span>
          </button>
        ))}
      </div>
      <div className="studio-setups-body">
        <div className="studio-setups-changes">
          <h3>What {picked.name} changes from yours</h3>
          {changes.adds.length + changes.removes.length === 0 && (
            <p className="studio-muted">Nothing: it is what you have.</p>
          )}
          <ul>
            {[...changes.adds, ...changes.removes].map((id) => {
              const item = byId(id);
              return (
                <li key={id} data-customization={id}>
                  <div className="studio-manager-text">
                    <span className="studio-card-name">
                      {changes.adds.includes(id) ? "Adds" : "Removes"} {item.name} <SourcePill item={item} />
                    </span>
                    <span className="studio-card-line">{item.line}</span>
                  </div>
                  <Switch on={studio.on.has(id)} label={item.name} onChange={(next) => studio.toggle(id, next)} />
                </li>
              );
            })}
          </ul>
          <div className="studio-actions">
            <button type="button" className="studio-button studio-button-primary" onClick={() => studio.tryOn(picked)}>
              Try {picked.name}
            </button>
            <button type="button" className="studio-button">
              Share link
            </button>
          </div>
        </div>
        <MiniCmux on={studio.on} />
      </div>
    </div>
  );
}

export function CustomizeStudio({
  layout,
  on,
  trying,
  selected = "motion",
}: {
  layout: StudioLayout;
  on: readonly Effect[];
  trying?: string;
  selected?: Effect;
}) {
  const studio = useStudio({ on, trying });
  return (
    <div className="customize-studio" data-layout={layout}>
      <header className="studio-header">
        <div>
          <h2>Customize</h2>
          <span className="studio-muted">
            {studio.on.size} of {CUSTOMIZATIONS.length} on · changes show live, nothing is saved until you keep it
          </span>
        </div>
        <button
          type="button"
          className="studio-button studio-button-primary"
          data-action="try-leo"
          onClick={() => studio.tryOn(SETUPS.find((setup) => setup.id === "leo")!)}
        >
          Try Leo's setup
        </button>
      </header>
      {studio.trying && <TrialBar setup={studio.trying} onKeep={studio.keep} onRevert={studio.revert} />}
      {layout === "store" && <StoreLayout studio={studio} selected={selected} />}
      {layout === "manager" && <ManagerLayout studio={studio} />}
      {layout === "setups" && <SetupsLayout studio={studio} initialSetup={trying ?? "leo"} />}
    </div>
  );
}
