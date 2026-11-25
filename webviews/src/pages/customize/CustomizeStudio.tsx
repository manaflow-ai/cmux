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

export type StudioLayout = "store" | "manager" | "setups" | "tiles";

/** A small cmux window: a sidebar of sessions, a chat with two messages and a composer. */
export function MiniCmux({
  on,
  size = "large",
  focus,
}: {
  on: ReadonlySet<Effect>;
  size?: "large" | "thumb";
  /** The customization this picture is about: the part it changes is outlined. */
  focus?: Effect;
}) {
  const classes = ["mini-cmux", `mini-cmux-${size}`, ...[...on].map((effect) => `fx-${effect}`)];
  return (
    <div className={classes.join(" ")} data-focus={focus} aria-hidden="true">
      <div className="mini-sidebar">
        <span className="mini-row mini-row-on" />
        <span className="mini-row" />
        <span className="mini-row" />
        <span className="mini-row" />
        {on.has("standup") && <span className="mini-chip">3 PRs</span>}
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
        <MiniCmux on={without} size="thumb" focus={id} />
        <figcaption>Before</figcaption>
      </figure>
      <figure>
        <MiniCmux on={withIt} size="thumb" focus={id} />
        <figcaption>After</figcaption>
      </figure>
    </div>
  );
}

/** The track alone, for a row that is itself the switch button. */
function sameSet(a: ReadonlySet<Effect>, b: readonly Effect[]) {
  return a.size === b.length && b.every((id) => a.has(id));
}

function SwitchTrack({ on }: { on: boolean }) {
  return <span className={on ? "studio-switch studio-switch-on" : "studio-switch"} />;
}

/** One customization as one button: the whole row flips it, so a fast pointer cannot miss. */
function SwitchRow({
  item,
  on,
  prefix,
  line,
  onChange,
  onPeek,
  peeked,
}: {
  item: Customization;
  on: boolean;
  prefix?: string;
  line?: string;
  onChange: (next: boolean) => void;
  onPeek?: () => void;
  peeked?: boolean;
}) {
  return (
    <li data-customization={item.id} data-peeked={peeked || undefined}>
      <button
        type="button"
        role="switch"
        aria-checked={on}
        className="studio-row"
        onClick={() => onChange(!on)}
        onPointerEnter={onPeek}
        onFocus={onPeek}
      >
        <span className="studio-manager-text">
          <span className="studio-card-name">
            {prefix && <span className="studio-prefix">{prefix} </span>}
            {item.name} <SourcePill item={item} />
          </span>
          <span className="studio-card-line">{line ?? item.line}</span>
        </span>
        <SwitchTrack on={on} />
      </button>
    </li>
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

type StudioState = {
  on: Set<Effect>;
  kept: Set<Effect>;
  trying: Setup | null;
  /** Counts keeps, reverts and tries: a layout that froze a comparison re-reads it when this moves. */
  epoch: number;
};

function useStudio(initial: { on: readonly Effect[]; trying?: string }) {
  const start = new Set(initial.on);
  const trying = SETUPS.find((setup) => setup.id === initial.trying) ?? null;
  const [state, setState] = useState<StudioState>({
    on: trying ? new Set(trying.on) : start,
    kept: start,
    trying,
    epoch: 0,
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
    tryOn: (setup: Setup) =>
      setState((before) => ({
        ...before,
        on: new Set(setup.on),
        trying: setup,
        epoch: before.epoch + 1,
      })),
    keep: () => setState((before) => ({ ...before, kept: before.on, trying: null, epoch: before.epoch + 1 })),
    revert: () => setState((before) => ({ ...before, on: before.kept, trying: null, epoch: before.epoch + 1 })),
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
              <MiniCmux on={new Set([entry.id])} size="thumb" focus={entry.id} />
              <span className="studio-card-name">
                <span className="studio-card-title">{entry.name}</span>
                {/* Always drawn, so turning one on never re-wraps its name. */}
                <span className="studio-pill studio-on-pill" data-shown={studio.on.has(entry.id) ? "" : undefined}>
                  On
                </span>
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
        <MiniCmux on={studio.on} focus={item.id} />
      </aside>
    </div>
  );
}

/** Manager: a mod manager's list, one switch per customization with its source and any conflict, and
 * the live window beside it; a setup picker on top swaps the whole list (VS Code profiles, game mod
 * managers' load order and conflict lines). */
function ManagerLayout({ studio }: { studio: Studio }) {
  const conflicts = liveConflicts(studio.on);
  // The row last pointed at or focused. It is never cleared, so its before/after keeps its place
  // and a pointer flicked across the list swaps pictures without moving anything.
  const [peek, setPeek] = useState<Effect>(CUSTOMIZATIONS[0]!.id);
  const current = SETUPS.find((setup) => sameSet(studio.on, setup.on));
  return (
    <div className="studio-manager">
      <div className="studio-manager-list">
        <div className="studio-manager-head">
          <span className="studio-muted">Setup</span>
          <div className="studio-track" role="group" aria-label="Setup">
            {SETUPS.map((setup) => (
              <button
                key={setup.id}
                type="button"
                className="studio-segment"
                data-setup={setup.id}
                aria-pressed={current?.id === setup.id}
                onClick={() => studio.tryOn(setup)}
              >
                {setup.name}
              </button>
            ))}
          </div>
          <span className="studio-muted studio-custom" data-shown={current ? undefined : ""}>
            Custom
          </span>
        </div>
        <ul>
          {CUSTOMIZATIONS.map((item) => {
            const lost = conflicts.find((conflict) => conflict.loser === item.id);
            return (
              <SwitchRow
                key={item.id}
                item={item}
                on={studio.on.has(item.id)}
                line={lost ? `${byId(lost.winner).name} wins: both change the sidebar.` : undefined}
                onChange={(next) => studio.toggle(item.id, next)}
                onPeek={() => setPeek(item.id)}
                peeked={peek === item.id}
              />
            );
          })}
        </ul>
      </div>
      <div className="studio-manager-preview">
        <MiniCmux on={studio.on} focus={peek} />
        <BeforeAfter base={studio.on} id={peek} />
        <p className="studio-muted studio-peek-name">{byId(peek).name}, without and with</p>
      </div>
    </div>
  );
}

/** Tiles: pictures first, the fewest words (the macOS Appearance tiles; the unnamed background tiles
 * beside a live window in onboarding's Make cmux Yours, #51603). The live window leads, the setups
 * sit beside it as one list, and every customization is one tile that is its own switch: its
 * picture, its name, on or off. Pointing at a tile outlines what it changes in the live window. */
function TilesLayout({ studio }: { studio: Studio }) {
  const [peek, setPeek] = useState<Effect | undefined>(undefined);
  const current = SETUPS.find((setup) => sameSet(studio.on, setup.on));
  const conflicts = liveConflicts(studio.on);
  return (
    <div className="studio-tiles">
      <div className="studio-tiles-top">
        <MiniCmux on={studio.on} focus={peek} />
        <div className="studio-tiles-setups" role="group" aria-label="Setup">
          <span className="studio-muted">Setups</span>
          {SETUPS.map((setup) => (
            <button
              key={setup.id}
              type="button"
              className="studio-setup-row"
              data-setup={setup.id}
              aria-pressed={current?.id === setup.id}
              onClick={() => studio.tryOn(setup)}
            >
              <span className="studio-radio" />
              <span className="studio-manager-text">
                <span className="studio-card-name">{setup.name}</span>
                <span className="studio-card-line">{setup.line}</span>
              </span>
            </button>
          ))}
          <span className="studio-muted studio-custom studio-card-line" data-shown={current ? undefined : ""}>
            Your own mix: it matches no setup.
          </span>
        </div>
      </div>
      <div className="studio-tile-grid">
        {CUSTOMIZATIONS.map((item) => {
          const on = studio.on.has(item.id);
          const lost = conflicts.find((conflict) => conflict.loser === item.id);
          return (
            <button
              key={item.id}
              type="button"
              role="switch"
              aria-checked={on}
              className="studio-tile"
              data-customization={item.id}
              title={lost ? `${byId(lost.winner).name} wins: both change the sidebar.` : item.line}
              onClick={() => studio.toggle(item.id, !on)}
              onPointerEnter={() => setPeek(item.id)}
              onPointerLeave={() => setPeek(undefined)}
              onFocus={() => setPeek(item.id)}
              onBlur={() => setPeek(undefined)}
            >
              <MiniCmux on={new Set([item.id])} size="thumb" focus={item.id} />
              <span className="studio-tile-foot">
                <span className="studio-tile-name">{item.name}</span>
                <SwitchTrack on={on} />
              </span>
              <span className="studio-card-line">
                {sourceLabel(item.source)}
                {lost ? " · overridden" : ""}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** Setups: people first. Pick whose setup to look at; it lists what it would change from yours, each
 * line a switch, over the live window of the result (Arc's spaces, VS Code's profile import). */
function SetupsLayout({ studio, initialSetup }: { studio: Studio; initialSetup: string }) {
  const [view, setView] = useState(() => ({
    picked: SETUPS.find((setup) => setup.id === initialSetup) ?? SETUPS[1]!,
    yours: studio.kept as ReadonlySet<Effect>,
    epoch: studio.epoch,
  }));
  // A keep or a revert changes what "yours" is; a flipped switch does not, so no row moves under the pointer.
  if (view.epoch !== studio.epoch) setView({ ...view, yours: studio.kept, epoch: studio.epoch });
  const picked = view.picked;
  const setPicked = (setup: Setup) => setView({ picked: setup, yours: studio.kept, epoch: studio.epoch });
  const changes = diff(view.yours, picked);
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
            <span className="studio-muted">
              {setup.on.length === 0 ? setup.line : `${setup.on.length} customizations`}
            </span>
          </button>
        ))}
      </div>
      <div className="studio-setups-body">
        <div className="studio-setups-changes">
          <h3>What {picked.name} changes from yours</h3>
          {/* The buttons sit above the list, and the list keeps room for every row: a setup with
              fewer changes moves nothing. */}
          <div className="studio-actions">
            <button type="button" className="studio-button studio-button-primary" onClick={() => studio.tryOn(picked)}>
              Try {picked.name}
            </button>
            <button type="button" className="studio-button">
              Share link
            </button>
          </div>
          <ul>
            {changes.adds.length + changes.removes.length === 0 && (
              <li className="studio-muted studio-nothing">Nothing: it is what you have.</li>
            )}
            {[...changes.adds, ...changes.removes].map((id) => {
              return (
                <SwitchRow
                  key={id}
                  item={byId(id)}
                  prefix={changes.adds.includes(id) ? "Adds" : "Removes"}
                  on={studio.on.has(id)}
                  onChange={(next) => studio.toggle(id, next)}
                />
              );
            })}
          </ul>
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
      <header className="studio-header" data-trying={studio.trying ? "" : undefined}>
        <div className="studio-header-text">
          <h2>Customize</h2>
          <span className="studio-muted" role="status">
            {studio.trying ? (
              <>
                Trying <strong>{studio.trying.name}</strong> · reverts when you quit unless you keep it
              </>
            ) : (
              `${studio.on.size} of ${CUSTOMIZATIONS.length} on · changes show live`
            )}
          </span>
        </div>
        {/* One slot, one height: Try, or the trial's Revert and Keep (the macOS display-change pattern). */}
        <div className="studio-header-actions">
          {studio.trying ? (
            <>
              <button type="button" className="studio-button" data-action="revert" onClick={studio.revert}>
                Revert
              </button>
              <button
                type="button"
                className="studio-button studio-button-primary"
                data-action="keep"
                onClick={studio.keep}
              >
                Keep
              </button>
            </>
          ) : (
            <button
              type="button"
              className="studio-button studio-button-primary"
              data-action="try-leo"
              /* Already Leo's setup: nothing to try. The button stays, so the header does not move. */
              disabled={sameSet(studio.on, SETUPS.find((setup) => setup.id === "leo")!.on)}
              onClick={() => studio.tryOn(SETUPS.find((setup) => setup.id === "leo")!)}
            >
              Try Leo's setup
            </button>
          )}
        </div>
      </header>
      {layout === "store" && <StoreLayout studio={studio} selected={selected} />}
      {layout === "manager" && <ManagerLayout studio={studio} />}
      {layout === "tiles" && <TilesLayout studio={studio} />}
      {layout === "setups" && <SetupsLayout studio={studio} initialSetup={trying ?? "leo"} />}
    </div>
  );
}
