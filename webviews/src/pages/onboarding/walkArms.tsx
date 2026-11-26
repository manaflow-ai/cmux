// l10n-allow-file: gallery arms for the intro walk, never shipped UI (nothing in the app imports this).
// Make cmux Yours, the intro walk's contested screens, as gallery arms to pick between (cmux#50394's
// pattern): 1 Pick a look (bundle tiles: grid, hero, list), 2 Trust and noise (rows, cards, folded
// into the look screen), 3 Tune (density 3 + More, all 5, 3 + Two-tone), 4 The exit (chat still,
// summary, Try it), and a footer with a persistent Undo / Redo pair against today's Skip / Continue.
// Every pick here is local state: no host op is sent except the shipped background, opacity and
// material rows the Tune arms reuse (MakeItYoursStep, unchanged), which the gallery's mock answers.
// One selection language with the shipped screen: a thin accent ring on a picked card or tile (a
// box-shadow, so nothing moves) and the segmented track whose plate slides (ui/motion/SlidingIndicator,
// transform only, placed at once under Reduce Motion). Every pick keeps the layout: example lines hold
// one line each, the hero tile keeps its box and only its faces change.
import { useState, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { DialogButton } from "../../ui/DialogButton";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";
import { Switch } from "../../ui/Switch";
import {
  WALK_BUNDLES,
  WALK_NOISE,
  WALK_PERMISSIONS,
  WALK_SHIPPED_NOISE,
  WALK_SHIPPED_PERMISSION,
  type WalkBundle,
} from "./fixtures";
import { MakeItYoursStep } from "./MakeItYoursStep";
import { Faces } from "./walkLook";
import { useOnboarding } from "./parts";

export type WalkScreen = "look" | "trust" | "tune" | "exit";
/** `strip`: the five as small tiles only (the look list folded while More is open). */
export type WalkLookLayout = "grid" | "hero" | "list" | "strip";
export type WalkTrustLayout = "rows" | "cards";
export type WalkTuneLayout = "three" | "five" | "twoTone";
export type WalkExitLayout = "chat" | "summary" | "tryIt";
export type WalkFooter = "today" | "undoRedo";

/** One arm, as plain gallery data. */
export interface WalkArm {
  screen: WalkScreen;
  layout: string;
  /** Look: trust and noise folded in as a More disclosure. Tune A: the outer densities shown. */
  more?: boolean;
  /** The More disclosure starts open. */
  open?: boolean;
  footer?: WalkFooter;
  /** The bundle first picked (the current look: House on a new Mac). */
  picked?: string;
  /** Picks already made, so the Undo / Redo pair shows enabled. */
  history?: number;
}

const SCREEN_TEXT: Record<WalkScreen, { title: string; sentence: string }> = {
  look: { title: "Pick a look", sentence: "A whole look in one click. Each follows your Mac's light or dark mode." },
  trust: { title: "Trust and noise", sentence: "How much agents may do on their own, and how loudly cmux tells you." },
  tune: { title: "Tune it", sentence: "Fit the window to you. Every row is in Settings > Appearance too." },
  exit: { title: "You're set", sentence: "Replay this walk any time from Settings > General or the palette." },
};

function BundleRadio({ bundle, picked, onPick }: { bundle: WalkBundle; picked: boolean; onPick: () => void }) {
  return (
    <input type="radio" name="walkLook" value={bundle.id} aria-label={bundle.name} checked={picked} onChange={onPick} />
  );
}

/** Step 1, Pick a look: the five bundles as A a grid of large tiles, B one hero tile over a strip, C a
 * list of rows. The current look is picked when the screen opens. */
function LookStep({
  layout,
  picked,
  onPick,
  extra,
}: {
  layout: WalkLookLayout;
  picked: string;
  onPick: (id: string) => void;
  extra?: ReactNode;
}) {
  const hero = WALK_BUNDLES.find((bundle) => bundle.id === picked) ?? WALK_BUNDLES[0]!;
  return (
    <div className="onb-make onb-walk" data-screen="look" data-layout={layout}>
      <fieldset className="onb-make-group">
        <legend className="onb-make-label">
          Look
          <span className="onb-make-label-value" aria-hidden="true">
            {hero.name}
          </span>
        </legend>
        {layout === "hero" && (
          <div className="onb-walk-hero" aria-hidden="true">
            <Faces bundle={hero} />
            <span className="onb-walk-hero-text">
              <span className="onb-make-option-title">{hero.name}</span>
              <span className="onb-walk-line">{hero.line}</span>
            </span>
          </div>
        )}
        <div className="onb-walk-looks">
          {WALK_BUNDLES.map((bundle) => {
            const checked = bundle.id === picked;
            return (
              <label key={bundle.id} className="onb-make-option onb-walk-look" data-checked={checked || undefined}>
                <BundleRadio bundle={bundle} picked={checked} onPick={() => onPick(bundle.id)} />
                <Faces bundle={bundle} />
                <span className="onb-walk-look-text">
                  <span className="onb-walk-look-name">
                    {bundle.name}
                    {bundle.id === "house" && <span className="onb-make-badge">Current</span>}
                  </span>
                  {layout === "list" && <span className="onb-walk-line">{bundle.line}</span>}
                </span>
              </label>
            );
          })}
          {layout === "grid" && <span className="onb-walk-look-more">More looks in Settings &gt; Appearance</span>}
        </div>
      </fieldset>
      {extra}
    </div>
  );
}

/** A segmented row of named picks with one example line under it, as the shipped density track. */
function SegmentRow<T extends { id: string; name: string; line?: string }>({
  name,
  label,
  items,
  value,
  shipped,
  onPick,
  withLine = true,
}: {
  name: string;
  label: string;
  items: readonly T[];
  value: string;
  shipped?: string;
  onPick: (id: string) => void;
  withLine?: boolean;
}) {
  const current = items.find((item) => item.id === value);
  return (
    <fieldset className="onb-make-group">
      <legend className="onb-make-label">{label}</legend>
      <div className="onb-make-segments ui-slide-host" style={{ "--onb-make-count": items.length } as CSSProperties}>
        <SlidingIndicator selected={value} selector="[data-checked]" className="onb-make-thumb" />
        {items.map((item) => (
          <label key={item.id} className="onb-make-segment ui-slide-item" data-checked={item.id === value || undefined}>
            <input
              type="radio"
              name={name}
              value={item.id}
              aria-label={item.name}
              checked={item.id === value}
              onChange={() => onPick(item.id)}
            />
            <span>{item.name}</span>
          </label>
        ))}
      </div>
      {withLine && (
        <p className="onb-walk-line onb-walk-example">
          {current?.line}
          {shipped === value && <span className="onb-walk-shipped"> (as cmux ships)</span>}
        </p>
      )}
    </fieldset>
  );
}

/** Step 3, Trust and noise: A two segmented rows, B three whole permission cards with noise as a row.
 * The shipped values are picked when it opens. */
function TrustRows({
  layout,
  permission,
  noise,
  onPermission,
  onNoise,
}: {
  layout: WalkTrustLayout;
  permission: string;
  noise: string;
  onPermission: (id: string) => void;
  onNoise: (id: string) => void;
}) {
  return (
    <>
      {layout === "cards" ? (
        <fieldset className="onb-make-group">
          <legend className="onb-make-label">Agents may</legend>
          <div className="onb-walk-cards">
            {WALK_PERMISSIONS.map((item) => {
              const checked = item.id === permission;
              return (
                <label key={item.id} className="onb-make-option onb-walk-card" data-checked={checked || undefined}>
                  <input
                    type="radio"
                    name="walkPermission"
                    value={item.id}
                    aria-label={item.name}
                    checked={checked}
                    onChange={() => onPermission(item.id)}
                  />
                  <span className="onb-make-option-text">
                    <span className="onb-make-option-title">
                      {item.name}
                      {item.id === WALK_SHIPPED_PERMISSION && <span className="onb-make-badge">As shipped</span>}
                    </span>
                    <span className="onb-make-option-detail">{item.line}</span>
                  </span>
                </label>
              );
            })}
          </div>
        </fieldset>
      ) : (
        <SegmentRow
          name="walkPermission"
          label="Agents may"
          items={WALK_PERMISSIONS}
          value={permission}
          shipped={WALK_SHIPPED_PERMISSION}
          onPick={onPermission}
        />
      )}
      <SegmentRow
        name="walkNoise"
        label="Notifications"
        items={WALK_NOISE}
        value={noise}
        shipped={WALK_SHIPPED_NOISE}
        onPick={onNoise}
      />
    </>
  );
}

const DENSITY_THREE = ["compact", "cozy", "comfortable"];

/** Step 4, Tune: the density track (3 with More, all 5, or 3 plus a Two-tone row), then the shipped
 * background, opacity and material rows (MakeItYoursStep with its own work and density rows hidden). */
function TuneStep({ layout, outer }: { layout: WalkTuneLayout; outer: boolean }) {
  const { store } = useOnboarding();
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [showOuter, setShowOuter] = useState(outer);
  const [twoTone, setTwoTone] = useState(false);
  const choices = state?.makeItYours;
  if (choices == null) return null;
  const densities =
    layout === "five" || showOuter
      ? choices.densities
      : choices.densities.filter((density) => DENSITY_THREE.includes(density.id));
  return (
    <div className="onb-make onb-walk" data-screen="tune" data-layout={layout}>
      <div className="onb-walk-density">
        <SegmentRow
          name="walkDensity"
          label="Density"
          items={densities}
          value={choices.density}
          withLine={false}
          onPick={(id) => store.call("cmux.onboarding.makeItYours.density", { value: id })}
        />
        {layout === "three" && (
          <button
            type="button"
            className="ui-button ui-btn onb-walk-more-button"
            data-variant="ghost"
            data-size="sm"
            aria-expanded={showOuter}
            onClick={() => setShowOuter((open) => !open)}
          >
            {showOuter ? "Fewer" : "More"}
          </button>
        )}
      </div>
      {layout === "twoTone" && (
        <div className="onb-walk-toggle-row">
          <span className="onb-walk-toggle-text">
            <span className="onb-make-adjust-label">Two-tone</span>
            <span className="onb-walk-line">Sidebar and tab bar in a second color from your theme.</span>
          </span>
          <Switch size="sm" checked={twoTone} onCheckedChange={setTwoTone} aria-label="Two-tone" />
        </div>
      )}
      <div className="onb-walk-tune-rest">
        <MakeItYoursStep choices={choices} />
      </div>
    </div>
  );
}

/** Step "exit" A: the destination as a still: a new chat, the composer focused, one suggested prompt. */
function ExitChat() {
  return (
    <div className="onb-walk" data-screen="exit" data-layout="chat">
      <p className="onb-make-label">After Continue</p>
      <div className="onb-walk-still" aria-hidden="true">
        <span className="onb-walk-still-side">
          {Array.from({ length: 5 }, (_, i) => (
            <span key={i} className="onb-walk-mini-row" data-active={i === 0 || undefined} />
          ))}
        </span>
        <span className="onb-walk-still-chat">
          <span className="onb-walk-still-empty">What should we work on?</span>
          <span className="onb-walk-still-suggest">Explain this project and suggest a first task</span>
          <span className="onb-walk-still-composer">
            <span className="onb-walk-still-caret" />
            Ask Claude or Codex anything
          </span>
        </span>
      </div>
      <p className="onb-walk-line">A new chat opens with the composer focused. Press Return to send the suggestion.</p>
    </div>
  );
}

/** Step "exit" B: what was picked, one Undo all, the replay line. */
function ExitSummary({ look, permission, noise }: { look: string; permission: string; noise: string }) {
  const { store } = useOnboarding();
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const choices = state?.makeItYours;
  const density = choices?.densities.find((item) => item.id === choices.density)?.name ?? "";
  const background =
    choices?.background == null
      ? "None"
      : (choices.backgrounds.find((item) => item.id === choices.background)?.name ?? "");
  const rows: [string, string][] = [
    ["Look", WALK_BUNDLES.find((bundle) => bundle.id === look)?.name ?? ""],
    ["How you work", choices?.workStyle === "terminal" ? "Terminal first" : "Agents first"],
    ["Agents may", WALK_PERMISSIONS.find((item) => item.id === permission)?.name ?? ""],
    ["Notifications", WALK_NOISE.find((item) => item.id === noise)?.name ?? ""],
    ["Density", density],
    ["Background", background],
  ];
  return (
    <div className="onb-walk" data-screen="exit" data-layout="summary">
      <dl className="onb-walk-summary">
        {rows.map(([label, value]) => (
          <div key={label} className="onb-walk-summary-row">
            <dt className="onb-make-adjust-label">{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
      <div className="onb-walk-summary-foot">
        <DialogButton dialogKey={null} className="ui-button ui-btn" data-variant="subtle" data-size="md">
          Undo All
        </DialogButton>
        <span className="onb-walk-line">Puts back every setting this walk changed, in one step.</span>
      </div>
    </div>
  );
}

/** Step "exit" C: Try it: two things to do, each checked off when done (the palette done here). */
function ExitTryIt() {
  return (
    <div className="onb-walk" data-screen="exit" data-layout="tryIt">
      <ol className="onb-walk-tries">
        <li className="onb-make-option onb-walk-try" data-done="">
          <span className="onb-walk-try-mark" aria-hidden="true" />
          <span className="onb-make-option-text">
            <span className="onb-make-option-title">
              Open the palette
              <kbd className="onb-walk-key">⌘</kbd>
              <kbd className="onb-walk-key">K</kbd>
            </span>
            <span className="onb-make-option-detail">Every command and setting, by name. Done.</span>
          </span>
        </li>
        <li className="onb-make-option onb-walk-try">
          <span className="onb-walk-try-mark" aria-hidden="true" />
          <span className="onb-make-option-text">
            <span className="onb-make-option-title">
              Start one agent
              <kbd className="onb-walk-key">⌘</kbd>
              <kbd className="onb-walk-key">N</kbd>
            </span>
            <span className="onb-make-option-detail">Claude or Codex in a new chat, with what you set here.</span>
          </span>
          <DialogButton dialogKey={null} className="ui-button ui-btn" data-variant="subtle" data-size="sm">
            New Chat
          </DialogButton>
        </li>
      </ol>
    </div>
  );
}

/** The footer: today's Skip / Continue, or the same with a persistent Undo / Redo pair leading. */
function WalkFooterRow({
  look,
  undo,
  redo,
  onUndo,
  onRedo,
  done,
}: {
  look: WalkFooter;
  undo: boolean;
  redo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  done: boolean;
}) {
  return (
    <footer className="onb-footer" data-walk-footer={look}>
      {look === "undoRedo" && (
        <div className="onb-walk-undo">
          <DialogButton
            dialogKey={{ command: "z" }}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            disabled={!undo}
            onClick={onUndo}
          >
            Undo
          </DialogButton>
          <DialogButton
            dialogKey={null}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            disabled={!redo}
            onClick={onRedo}
          >
            Redo
          </DialogButton>
        </div>
      )}
      <div className="onb-footer-buttons">
        {!done && (
          <DialogButton dialogKey="escape" className="ui-button ui-btn" data-variant="subtle" data-size="md">
            Skip
          </DialogButton>
        )}
        <DialogButton dialogKey="return" className="ui-button ui-btn" data-variant="solid" data-size="md">
          {done ? "Start" : "Continue"}
        </DialogButton>
      </div>
    </footer>
  );
}

type Picks = { look: string; permission: string; noise: string };

/** One walk screen in the onboarding window's scaffold (title, sentence, body, footer). The picks live
 * here, with a history the Undo / Redo footer steps through. */
export function WalkArmScreen({ arm }: { arm: WalkArm }) {
  const first: Picks = {
    look: arm.picked ?? "house",
    permission: WALK_SHIPPED_PERMISSION,
    noise: WALK_SHIPPED_NOISE,
  };
  // A fixture's earlier picks: walked through the looks, so Undo has something to put back.
  const earlier: Picks[] = Array.from({ length: arm.history ?? 0 }, (_, i) => ({
    ...first,
    look: WALK_BUNDLES[i % WALK_BUNDLES.length]!.id,
  }));
  const [history, setHistory] = useState<{ past: Picks[]; now: Picks; future: Picks[] }>({
    past: earlier,
    now: first,
    future: [],
  });
  const [open, setOpen] = useState(arm.open ?? false);
  const pick = (change: Partial<Picks>) =>
    setHistory(({ past, now }) => ({ past: [...past, now], now: { ...now, ...change }, future: [] }));
  const undo = () =>
    setHistory(({ past, now, future }) =>
      past.length === 0
        ? { past, now, future }
        : { past: past.slice(0, -1), now: past.at(-1)!, future: [now, ...future] },
    );
  const redo = () =>
    setHistory(({ past, now, future }) =>
      future.length === 0 ? { past, now, future } : { past: [...past, now], now: future[0]!, future: future.slice(1) },
    );
  const { now } = history;
  const text = SCREEN_TEXT[arm.screen];
  const trust = (
    <TrustRows
      layout={arm.screen === "trust" ? (arm.layout as WalkTrustLayout) : "rows"}
      permission={now.permission}
      noise={now.noise}
      onPermission={(id) => pick({ permission: id })}
      onNoise={(id) => pick({ noise: id })}
    />
  );
  let body: ReactNode;
  if (arm.screen === "look") {
    body = (
      <LookStep
        // With More open the list folds to a strip, so both trust rows fit the window with no scroll.
        layout={arm.more && open ? "strip" : (arm.layout as WalkLookLayout)}
        picked={now.look}
        onPick={(id) => pick({ look: id })}
        extra={
          arm.more ? (
            <div className="onb-walk-disclosure" data-open={open || undefined}>
              <button
                type="button"
                className="ui-button ui-btn onb-walk-more-button"
                data-variant="ghost"
                data-size="sm"
                aria-expanded={open}
                onClick={() => setOpen((value) => !value)}
              >
                {open ? "Fewer" : "More: agents and notifications"}
              </button>
              {open && trust}
            </div>
          ) : undefined
        }
      />
    );
  } else if (arm.screen === "trust") {
    body = (
      <div className="onb-make onb-walk" data-screen="trust" data-layout={arm.layout}>
        {trust}
      </div>
    );
  } else if (arm.screen === "tune") {
    body = <TuneStep layout={arm.layout as WalkTuneLayout} outer={arm.more ?? false} />;
  } else {
    body =
      arm.layout === "summary" ? (
        <ExitSummary look={now.look} permission={now.permission} noise={now.noise} />
      ) : arm.layout === "tryIt" ? (
        <ExitTryIt />
      ) : (
        <ExitChat />
      );
  }
  return (
    <div className="onboarding onb-walk-window" data-step="makeItYours">
      <div className="onb-scaffold" data-step="makeItYours">
        <header className="onb-header">
          <h1 className="onb-title">{arm.screen === "exit" && arm.layout === "tryIt" ? "Try it" : text.title}</h1>
          <p className="onb-sentence">{text.sentence}</p>
        </header>
        <div className="onb-body">{body}</div>
        <WalkFooterRow
          look={arm.footer ?? "today"}
          undo={history.past.length > 0}
          redo={history.future.length > 0}
          onUndo={undo}
          onRedo={redo}
          done={arm.screen === "exit"}
        />
      </div>
    </div>
  );
}
