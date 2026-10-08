// The compare view (`view=compare`): every arm of an entry's experiment side by side, each cell the
// same variant under the same controls at the same size and scale, labeled with its arm. Replay
// runs the experiment's script in every cell at the same time: the shell sends step N to all
// cells and waits for all of them before step N+1, so the arms stay in lockstep however long each
// one's motion takes. Speed, loop, the enlarged cell, the pick and the resting step are URL state
// (compare.ts), so "Copy link" hands over the exact view; the line under it says it in words.
// A developer tool: its labels are English, like the rest of the shell.
import { useCallback, useRef, useState, useSyncExternalStore } from "react";
import {
  clampStep,
  COMPARE_GRIDS,
  COMPARE_SPEEDS,
  compareSummary,
  visibleArms,
  type CompareFrameCommand,
  type CompareFrameEvent,
  type CompareState,
  type StepStats,
} from "../compare";
import { frameQuery, widthPx, WIDTHS, type GalleryEnv } from "../env";
import { stageHeight, type ArmMeasurement, type GalleryEntry, type GalleryExperiment } from "../format";
import { entryPaneSize, fitScale } from "../window";
import metrics from "virtual:cmux-gallery/metrics";

/** Published matrix runs (scripts/gallery-matrix publishRun): the strips the captions link to. */
const MATRIX_URL = "https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix";

/** Pause between two synced steps, at 1x, so each step's end state reads before the next. */
const STEP_HOLD_MS = 450;

type Cell = { iframe: HTMLIFrameElement; ready: boolean };

/** The cells' frames and the replay loop; one per mounted compare view. */
function createCompareRun() {
  const cells = new Map<string, Cell>();
  const waiters = new Set<(arm: string, event: CompareFrameEvent) => void>();
  const stats = new Map<string, StepStats>();
  let status = "idle";
  let version = 0;
  const listeners = new Set<() => void>();
  const changed = () => {
    version += 1;
    for (const listener of listeners) listener();
  };
  const receive = (event: MessageEvent) => {
    const data = event.data as CompareFrameEvent | null;
    if (data?.type !== "cmux-exp") return;
    for (const [arm, cell] of cells) {
      if (cell.iframe.contentWindow !== event.source) continue;
      if (data.event === "ready") cell.ready = true;
      if (data.event === "step-done") stats.set(arm, data.stats);
      for (const waiter of waiters) waiter(arm, data);
      changed();
    }
  };
  /** Resolves when every one of `arms` sent `match`. */
  const all = (arms: string[], match: (event: CompareFrameEvent) => boolean, already: (arm: string) => boolean) =>
    new Promise<void>((resolve, reject) => {
      const pending = new Set(arms.filter((arm) => !already(arm)));
      if (!pending.size) return resolve();
      const waiter = (arm: string, event: CompareFrameEvent) => {
        if (event.event === "error") {
          waiters.delete(waiter);
          reject(new Error(`${arm}: ${event.message}`));
        } else if (match(event)) {
          pending.delete(arm);
          if (!pending.size) {
            waiters.delete(waiter);
            resolve();
          }
        }
      };
      waiters.add(waiter);
    });
  const hold = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  let token = 0;
  return {
    subscribe(listener: () => void) {
      if (!listeners.size) addEventListener("message", receive);
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
        if (!listeners.size) removeEventListener("message", receive);
      };
    },
    snapshot: () => version,
    status: () => status,
    stats: (arm: string) => stats.get(arm),
    /** A cell's iframe mounted; the returned function forgets it (only if it is still the arm's). */
    frame(arm: string, iframe: HTMLIFrameElement) {
      cells.set(arm, { iframe, ready: false });
      return () => {
        if (cells.get(arm)?.iframe === iframe) cells.delete(arm);
      };
    },
    /** Every cell's frame reloaded: they report ready again. */
    reloaded() {
      for (const cell of cells.values()) cell.ready = false;
      stats.clear();
    },
    stop() {
      token += 1;
      status = "idle";
      changed();
    },
    /** Runs steps `from` to `to - 1` in every listed cell, in lockstep. Returns false when stopped. */
    async run(arms: string[], from: number, to: number, speed: () => number, onStep: (done: number) => void) {
      const mine = ++token;
      status = "waiting for cells";
      changed();
      try {
        await all(
          arms,
          (event) => event.event === "ready",
          (arm) => cells.get(arm)?.ready === true,
        );
        for (let index = from; index < to; index += 1) {
          if (mine !== token) return false;
          status = `step ${index + 1} of ${to}`;
          changed();
          const command: CompareFrameCommand = { type: "cmux-exp", op: "step", index, speed: speed() };
          const done = all(
            arms,
            (event) => event.event === "step-done" && event.index === index,
            () => false,
          );
          for (const arm of arms) cells.get(arm)?.iframe.contentWindow?.postMessage(command, "*");
          await done;
          onStep(index + 1);
          if (index + 1 < to) await hold(STEP_HOLD_MS / speed());
        }
        return mine === token;
      } catch (error) {
        status = `error: ${error instanceof Error ? error.message : String(error)}`;
        changed();
        return false;
      } finally {
        if (mine === token && !status.startsWith("error")) {
          status = "idle";
          changed();
        }
      }
    },
  };
}
type CompareRun = ReturnType<typeof createCompareRun>;

const fmt = (stats: Pick<StepStats, "p50" | "p95" | "max" | "over16">) =>
  `p50 ${stats.p50} · p95 ${stats.p95} · max ${stats.max} ms · ${stats.over16} over 16.7`;

function measuredLine(measured: ArmMeasurement): string {
  const plan = measured.planMs !== undefined ? ` · plan ${measured.planMs} ms` : "";
  return `VM ${measured.engine} (${measured.run}): ${fmt(measured)}${plan}`;
}

export function CompareView({
  entry,
  experiment,
  variant,
  env,
  tune,
  compare,
  room,
  onCompare,
}: {
  entry: GalleryEntry;
  experiment: GalleryExperiment;
  variant: string;
  env: GalleryEnv;
  /** The edited tunables (router.tsx ShellSearch `tune`): every arm runs with them. */
  tune?: string;
  compare: CompareState;
  room: { width: number; height: number };
  /** Writes the compare state into the URL (`replace` for progress the viewer did not click). */
  onCompare: (next: CompareState, replace?: boolean) => void;
}) {
  const [run] = useState(createCompareRun);
  useSyncExternalStore(run.subscribe, run.snapshot);
  // Every reload of the cells is one generation; a cell's frame URL is fixed for its generation,
  // so the URL's step moving forward during a replay does not reload the frames.
  const [generation, setGeneration] = useState(0);
  const [baseStep, setBaseStep] = useState(() => clampStep(experiment, compare.step));
  const latest = useRef({ compare, onCompare });
  latest.current = { compare, onCompare };
  const [copied, setCopied] = useState(false);
  const { definition } = experiment;
  const arms = visibleArms(definition, compare);
  const step = clampStep(experiment, compare.step);
  const steps = experiment.script.length;
  const set = (patch: Partial<CompareState>, replace = false) =>
    latest.current.onCompare({ ...latest.current.compare, ...patch }, replace);
  const reload = (from: number) => {
    run.stop();
    run.reloaded();
    setBaseStep(from);
    setGeneration((value) => value + 1);
  };
  const play = async (from: number, to: number) => {
    const finished = await run.run(
      arms,
      from,
      to,
      () => latest.current.compare.speed,
      (done) => set({ step: done }, true),
    );
    if (finished && latest.current.compare.loop && to === steps) {
      reload(0);
      set({ step: 0 }, true);
      // The reloaded cells report ready before the next pass starts (run waits for them).
      queueMicrotask(() => void play(0, steps));
    }
  };
  const replay = () => {
    reload(0);
    set({ step: 0 }, true);
    queueMicrotask(() => void play(0, steps));
  };
  const summary = compareSummary(entry.id, variant, experiment, compare, {
    theme: env.theme,
    locale: env.locale,
    reducedMotion: env.reducedMotion,
  });
  // The cells render at the entry's real size: a component at its pane width, a page at its pane.
  const component = entry.host === "component";
  const frame = component
    ? { width: widthPx(env.width, entry.widths ?? WIDTHS), height: env.height || stageHeight(entry, variant) }
    : entryPaneSize(env.window, env.layout, env.density, metrics);
  const cellEnv: GalleryEnv = component ? { ...env, frame: "component" } : { ...env, frame: "window" };
  const focused = compare.focus && arms.includes(compare.focus) ? compare.focus : "";
  const shown = focused ? [focused] : arms;
  const fit = fitScale(frame, { width: Math.max(320, room.width - 4), height: Math.max(240, room.height - 60) });
  const scale = focused ? fit : env.zoom === "fit" ? (component ? 1 : Math.min(1, 420 / frame.width)) : env.zoom;
  const columns =
    compare.grid === "auto"
      ? `repeat(auto-fill, ${Math.ceil(frame.width * scale)}px)`
      : compare.grid === "row"
        ? undefined
        : `repeat(${compare.grid}, ${Math.ceil(frame.width * scale)}px)`;
  return (
    <section className="gallery-compare" aria-label={`Compare ${definition.title}`}>
      <div className="gallery-compare-bar">
        <p className="gallery-compare-description">
          <strong>{definition.title}</strong> <code>{definition.id}</code> · {definition.description} Default arm:{" "}
          <code>{definition.defaultArm}</code>.
        </p>
        <div className="gallery-controls">
          <fieldset className="gallery-segmented">
            <legend>Arms</legend>
            {Object.keys(definition.arms).map((id) => (
              <label key={id}>
                <input
                  type="checkbox"
                  aria-label={`Show arm ${id}`}
                  checked={arms.includes(id)}
                  onChange={(event) => {
                    const next = event.target.checked ? [...arms, id] : arms.filter((arm) => arm !== id);
                    const ordered = Object.keys(definition.arms).filter((arm) => next.includes(arm));
                    set({ arms: ordered.length === Object.keys(definition.arms).length ? [] : ordered });
                  }}
                />
                {id}
              </label>
            ))}
          </fieldset>
          <fieldset className="gallery-segmented">
            <legend>Grid</legend>
            {COMPARE_GRIDS.map((grid) => (
              <label key={grid}>
                <input
                  type="radio"
                  name="compare-grid"
                  aria-label={`Grid ${grid}`}
                  checked={compare.grid === grid}
                  onChange={() => set({ grid })}
                />
                {grid === "auto" ? "wrap" : grid === "row" ? "one row" : `${grid} col`}
              </label>
            ))}
          </fieldset>
          <fieldset className="gallery-segmented">
            <legend>Speed</legend>
            {COMPARE_SPEEDS.map((speed) => (
              <label key={speed}>
                <input
                  type="radio"
                  name="compare-speed"
                  aria-label={`Speed ${speed}x`}
                  checked={compare.speed === speed}
                  onChange={() => set({ speed })}
                />
                {speed}x
              </label>
            ))}
          </fieldset>
          <label className="gallery-check">
            <input
              type="checkbox"
              aria-label="Loop"
              checked={compare.loop}
              onChange={(event) => set({ loop: event.target.checked })}
            />
            Loop
          </label>
          <button type="button" className="gallery-compare-primary" onClick={replay}>
            Replay all
          </button>
          <button type="button" onClick={() => void play(step, step + 1)} disabled={step >= steps}>
            Next step
          </button>
          <button
            type="button"
            onClick={() => {
              const back = Math.max(0, step - 1);
              set({ step: back });
              reload(back);
            }}
            disabled={step === 0}
          >
            Previous step
          </button>
          <button
            type="button"
            onClick={() => {
              set({ step: 0, loop: false });
              reload(0);
            }}
          >
            Reset
          </button>
          <span className="gallery-note" aria-live="polite">
            {run.status() === "idle"
              ? step
                ? `at step ${step} of ${steps}: ${experiment.script[step - 1]!.name}`
                : `at the start (${steps} steps: ${experiment.script.map((one) => one.name).join(", ")})`
              : run.status()}
          </span>
        </div>
        <div className="gallery-compare-link">
          <button
            type="button"
            onClick={() => {
              void navigator.clipboard?.writeText(`${location.href}\n${summary}`).then(() => setCopied(true));
            }}
          >
            {copied ? "Copied" : "Copy link"}
          </button>
          <code className="gallery-compare-summary">{summary}</code>
        </div>
      </div>
      <div
        className={`gallery-compare-grid${compare.grid === "row" ? " gallery-compare-grid--row" : ""}`}
        style={{ gridTemplateColumns: columns }}
      >
        {shown.map((arm) => (
          <CompareCell
            key={`${arm}-${generation}`}
            run={run}
            arm={arm}
            experiment={experiment}
            src={`frame.html?${frameQuery({ entry: entry.id, variant, tune }, cellEnv)}&exp=${encodeURIComponent(definition.id)}&arm=${encodeURIComponent(arm)}${baseStep ? `&step=${baseStep}` : ""}`}
            frame={frame}
            scale={scale}
            picked={compare.pick === arm}
            focused={focused === arm}
            onPick={() => set({ pick: compare.pick === arm ? "" : arm })}
            onFocus={() => set({ focus: focused === arm ? "" : arm })}
          />
        ))}
      </div>
    </section>
  );
}

function CompareCell({
  run,
  arm,
  experiment,
  src,
  frame,
  scale,
  picked,
  focused,
  onPick,
  onFocus,
}: {
  run: CompareRun;
  arm: string;
  experiment: GalleryExperiment;
  src: string;
  frame: { width: number; height: number };
  scale: number;
  picked: boolean;
  focused: boolean;
  onPick: () => void;
  onFocus: () => void;
}) {
  const definition = experiment.definition.arms[arm]!;
  const stats = run.stats(arm);
  const measured = experiment.measurements?.[arm];
  const isDefault = experiment.definition.defaultArm === arm;
  // The iframe's src is fixed for the cell's life: the cell is keyed by the reload generation.
  const [fixedSrc] = useState(src);
  // Stable, so a re-render never re-registers the frame (and never forgets that it is ready).
  const frameRef = useCallback(
    (iframe: HTMLIFrameElement | null) => (iframe ? run.frame(arm, iframe) : undefined),
    [run, arm],
  );
  return (
    <figure className="gallery-compare-cell" data-picked={picked ? "" : undefined} data-arm={arm}>
      <figcaption>
        <div className="gallery-compare-cell-head">
          <strong className="gallery-compare-arm">{arm}</strong>
          <span>{definition.label}</span>
          {isDefault && <span className="gallery-experimental">default</span>}
          <button type="button" aria-pressed={picked} className="gallery-compare-pick" onClick={onPick}>
            {picked ? "Picked" : "Pick"}
          </button>
          <button type="button" aria-pressed={focused} onClick={onFocus}>
            {focused ? "Back to grid" : "Enlarge"}
          </button>
          <a href={fixedSrc} target="_blank" rel="noreferrer">
            open
          </a>
        </div>
        <div className="gallery-note">{definition.description}</div>
        {measured && (
          <div className="gallery-compare-measure">
            {measuredLine(measured)}
            {measured.strip && (
              <>
                {" · "}
                <a href={`${MATRIX_URL}/${measured.run}/${measured.strip}`} target="_blank" rel="noreferrer">
                  frame strip
                </a>
              </>
            )}
          </div>
        )}
        {stats && (
          <div className="gallery-compare-measure">
            here, last step: {fmt(stats)} · {stats.durationMs} ms · plan {stats.planMs} ms
          </div>
        )}
      </figcaption>
      <div className="gallery-window" style={{ width: frame.width * scale, height: frame.height * scale }}>
        <iframe
          ref={frameRef}
          title={`${experiment.definition.id} arm ${arm}`}
          src={fixedSrc}
          style={{ width: frame.width, height: frame.height, transform: `scale(${scale})`, border: 0 }}
        />
      </div>
    </figure>
  );
}
