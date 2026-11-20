// Settings > Updates' Channels card: every release channel's recent builds from the host's
// `cmux.settings.channels.state` (the feed's notes index, canary verdicts and pulls), read once
// when the card shows. Following tracks the Channel row above it at once. Each build says how it fared, whether this Mac runs or kept it, and links
// to its commit, its PRs and the changes since the installed build; every text is the host's.
// Picking a slower channel the running build is not on shows the way back: Go Back restarts
// once into the build this Mac kept from it (the host's rollback path), or a line says the
// running build stays until that channel passes it. Every other build (older or newer, kept or
// not, never the pulled ones) has a Switch, shown while the pointer is on its row: one restart into
// it, downloaded first unless kept (Leo: "be able to hot swap your dev build for any other dev build").
// A switch can take minutes (a ~200 MB download, its checks, the restart), so while one runs the
// clicked control stays shown with a spinner and the host's stage ("Downloading… 42%"), a thin bar
// runs under its row, and every other Switch and Go Back waits (Leo 2026-11-11: "reverting the app
// to previous nightly is really slow/doesn't work very well sometimes?/needs less shitty ui").
import { Button } from "../../../ui/Button";
import { useEffect, useRef, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useSettingsState, useStore } from "../context";
import { channelsQuery } from "../sectionQueries";
import type {
  ChannelBuild,
  ChannelMachines,
  ChannelSwitch,
  ChannelTrack,
  ChannelsProgress,
  ChannelsState,
} from "../ops";
import { LOAD_FADE_CLASS, useLoadFade } from "../../../agent-session/shared/loadFade";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";

/** One of the card's restart controls: a track's Switch or the way back's Go Back. */
type Target = { kind: "switch" | "go_back"; ring: string; build: string };

/** The card's one running switch, handed to every row: `active` is the control that shows it
 * (null: none runs), `progress` the host's stage for it, `failure` the last refusal and its row. */
type Run = {
  active: Target | null;
  progress: ChannelsProgress | null;
  failure: { target: Target; message: string } | null;
  start: (target: Target) => void;
};

const same = (a: Target | null | undefined, b: Target) =>
  !!a && a.kind === b.kind && a.ring === b.ring && a.build === b.build;

/** The control's spinner and label while it runs: the host's stage once it says one, else the
 * control's own text (the click shows at once, before the first stage arrives). */
function RunLabel({ progress, idle }: { progress: ChannelsProgress | null; idle: string }) {
  return (
    <>
      <Spinner size={12} loading className="channel-run-spinner" />
      <span className="channel-run-label">{progress?.label ?? idle}</span>
    </>
  );
}

/** The thin bar under the running row, App Update's own (styles.css): the download's share, else
 * an empty track while it checks or restarts (the spinner carries the motion). */
function RunBar({ progress }: { progress: ChannelsProgress | null }) {
  const fraction = progress?.fraction ?? null;
  const percent = fraction === null ? null : Math.round(Math.min(1, Math.max(0, fraction)) * 100);
  return (
    <progress
      className="app-update-progress channel-progress"
      data-channel-progress={percent === null ? "indeterminate" : String(percent)}
      max={100}
      {...(percent === null ? {} : { value: percent })}
      aria-label={progress?.label}
    />
  );
}

function BuildRow({
  build,
  ring,
  labels,
  run,
}: {
  build: ChannelBuild;
  ring: string;
  labels: ChannelsState["labels"];
  run: Run;
}) {
  const target: Target = { kind: "switch", ring, build: build.build };
  const running = same(run.active, target);
  const failure = same(run.failure?.target, target) ? run.failure!.message : null;
  return (
    <div
      className="row channel-build"
      data-channel-build={build.build}
      data-health={build.health}
      data-running={running ? "" : undefined}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title selectable">{build.version}</div>
          <div className="row-help">
            {build.date}
            {build.commit && build.commit_url && (
              <>
                {" · "}
                <a href={build.commit_url} title={labels.commit} className="channel-link font-mono">
                  {build.commit}
                </a>
              </>
            )}
            {build.prs.map((pr) => (
              <span key={pr.number}>
                {" · "}
                <a href={pr.url} className="channel-link" data-channel-pr={pr.number}>{`#${pr.number}`}</a>
              </span>
            ))}
            {build.compare_url && (
              <>
                {" · "}
                <a href={build.compare_url} className="channel-link" data-channel-compare="">
                  {labels.compare}
                </a>
              </>
            )}
          </div>
          {build.pulled_reason && <div className="row-error">{build.pulled_reason}</div>}
          {failure && <div className="row-error">{failure}</div>}
        </div>
        <div className="row-control">
          {/* First, so the badges keep the card's control edge while it is hidden (it keeps its
              place, transparent) and nothing moves when it shows. While it runs it stays shown
              (data-busy) with the host's stage, and every other one waits. */}
          {build.switch && labels.switch && (
            <Button
              type="button"
              className="button channel-switch"
              data-channel-switch-build={build.build}
              data-busy={running ? "" : undefined}
              aria-busy={running || undefined}
              disabled={run.active !== null}
              onClick={() => run.start(target)}
            >
              {running ? <RunLabel progress={run.progress} idle={labels.switch} /> : labels.switch}
            </Button>
          )}
          {build.installed && (
            <span className="badge" data-channel-here="">
              {labels.you_are_here}
            </span>
          )}
          {build.kept && <span className="badge">{labels.kept}</span>}
          {build.health_title && (
            <span className={build.health === "held" || build.health === "pulled" ? "badge badge-warning" : "badge"}>
              {build.health_title}
            </span>
          )}
        </div>
      </div>
      {running && <RunBar progress={run.progress} />}
    </div>
  );
}

function Track({
  track,
  followed,
  labels,
  run,
}: {
  track: ChannelTrack;
  followed: boolean;
  labels: ChannelsState["labels"];
  run: Run;
}) {
  return (
    <div className="rows" data-channel={track.ring}>
      <div className="row">
        <div className="row-main">
          <div className="row-label">
            <div className="row-title">{track.title}</div>
            {track.empty && <div className="row-help">{track.empty}</div>}
          </div>
          <div className="row-control">
            {followed && (
              <span className="badge" data-channel-followed="">
                {labels.following}
              </span>
            )}
            {track.release_url && (
              <a href={track.release_url} className="channel-link">
                {labels.release}
              </a>
            )}
          </div>
        </div>
      </div>
      {track.builds.map((build) => (
        <BuildRow key={build.build} build={build} ring={track.ring} labels={labels} run={run} />
      ))}
    </div>
  );
}

function SwitchRow({ way, run }: { way: ChannelSwitch; run: Run }) {
  const target: Target | null = way.build ? { kind: "go_back", ring: way.ring, build: way.build } : null;
  const running = !!target && same(run.active, target);
  const failure = target && same(run.failure?.target, target) ? run.failure!.message : null;
  return (
    <div className="rows" data-channel-switch={way.ring}>
      <div className="row" data-running={running ? "" : undefined}>
        <div className="row-main">
          <div className="row-label">
            <div className="row-help">{way.detail}</div>
            {failure && <div className="row-error">{failure}</div>}
          </div>
          {target && way.action && (
            <div className="row-control">
              <Button
                type="button"
                className="button channel-switch"
                data-channel-go-back={way.build}
                data-busy={running ? "" : undefined}
                aria-busy={running || undefined}
                disabled={run.active !== null}
                onClick={() => run.start(target)}
              >
                {running ? <RunLabel progress={run.progress} idle={way.action} /> : way.action}
              </Button>
            </div>
          )}
        </div>
        {running && <RunBar progress={run.progress} />}
      </div>
    </div>
  );
}

/** The row of other machines: one line each, and an Update button on a line the app can update
 * (a machine too old to update in place). The click's result comes back as the row's push. */
function MachinesRow({ machines }: { machines: ChannelMachines }) {
  const store = useStore();
  const [busy, setBusy] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const update = (id: string) => {
    setBusy(id);
    setFailure(null);
    void store.channelsUpdateMachine(id).then((why) => {
      setBusy(null);
      setFailure(why);
    });
  };
  return (
    <div className="rows" data-channel-machines="">
      <div className="row">
        <div className="row-main">
          <div className="row-label">
            <div className="row-title">{machines.title}</div>
            {failure && <div className="row-error">{failure}</div>}
          </div>
        </div>
      </div>
      {machines.lines.map((line, index) => {
        const id = machines.updates?.[index] ?? null;
        return (
          <div key={line} className="row">
            <div className="row-main">
              <div className="row-label">
                <div className="row-help selectable" data-channel-machine="">
                  {line}
                </div>
              </div>
              {id && machines.updateLabel && (
                <div className="row-control">
                  <Button
                    type="button"
                    className="button"
                    data-channel-update-machine={id}
                    disabled={busy !== null}
                    onClick={() => update(id)}
                  >
                    {machines.updateLabel}
                  </Button>
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

/** The control that shows a switch this card did not start (opened mid-switch, or the palette's
 * Install an Earlier Nightly…): the way back if it restarts into that build, else its row on the
 * followed channel, else its first row. A build no row lists shows nowhere; the buttons still wait. */
function runningTarget(
  build: string,
  way: ChannelSwitch | null,
  tracks: ChannelTrack[],
  followed: string | undefined,
): Target {
  if (way?.build === build && way.action) return { kind: "go_back", ring: way.ring, build };
  const lists = (track: ChannelTrack) => track.builds.some((row) => row.build === build && row.switch);
  const track = tracks.find((track) => track.ring === followed && lists(track)) ?? tracks.find(lists);
  return { kind: "switch", ring: track?.ring ?? "", build };
}

/** The `?focus=` value that scrolls to this card: the palette's Install an Earlier Nightly… opens
 * `#/settings/updates?focus=channels:N`, a new N each time, so a second open scrolls back to it. */
export const CHANNELS_FOCUS = "channels";

const revealsCard = (focus: string | null) =>
  focus === CHANNELS_FOCUS || (focus?.startsWith(`${CHANNELS_FOCUS}:`) ?? false);

export function ChannelsCard({ focus = null }: { focus?: string | null }) {
  const store = useStore();
  // The row's value moves before the host has the write, so the card marks it, not a re-read.
  const ring = useSettingsState().rows.get("updates.channel")?.value;
  const shown = typeof ring === "string" ? ring : undefined;
  // One read per picked channel (the way back depends on it); the route's loader read the current
  // one, and the last answer stays while a new pick's read is out.
  const state = useQuery({ ...channelsQuery(store, shown), placeholderData: keepPreviousData }).data ?? null;
  // Scrolls to the card once it draws, and again for each new focus value naming it.
  const card = useRef<HTMLElement>(null);
  const drawn = state !== null;
  useEffect(() => {
    if (drawn && revealsCard(focus)) card.current?.scrollIntoView?.({ block: "start" });
  }, [drawn, focus]);
  // The card arrives with the host's lists: after a blank first paint it fades in (shared/loadFade.ts).
  const fade = useLoadFade(Boolean(state));
  // The control last clicked here, and whether its reply is out: the stages arrive as the read's
  // `progress` meanwhile and show on it, success restarts the app, and a refusal comes back and
  // shows in that control's row.
  const [clicked, setClicked] = useState<Target | null>(null);
  const [waiting, setWaiting] = useState(false);
  const [failure, setFailure] = useState<Run["failure"]>(null);
  if (!state) return null;
  const progress = state.progress ?? null;
  const followedRing = typeof ring === "string" ? ring : state.tracks.find((track) => track.followed)?.ring;
  // Only the picked channel's way back: a read for an earlier pick never offers its button.
  const way = state.switch && (shown === undefined || state.switch.ring === shown) ? state.switch : null;
  const active = !progress
    ? waiting
      ? clicked
      : null
    : clicked?.build === progress.build
      ? clicked
      : runningTarget(progress.build, way, state.tracks, followedRing);
  const run: Run = {
    active,
    progress: progress && active?.build === progress.build ? progress : null,
    failure,
    start: (target) => {
      setClicked(target);
      setWaiting(true);
      setFailure(null);
      const reply =
        target.kind === "go_back"
          ? store.channelsGoBack(target.ring, target.build)
          : store.channelsSwitchBuild(target.build);
      void reply.then((why) => {
        setWaiting(false);
        setFailure(why ? { target, message: why } : null);
      });
    },
  };
  return (
    <section className={fade ? `group ${LOAD_FADE_CLASS}` : "group"} data-card="channels" ref={card}>
      <h3 className="group-title">{state.title}</h3>
      <div className="row-help">{state.installed}</div>
      {/* The app's acpmux daemon: its build, and whether it is up to date or restarting. */}
      {state.daemon && (
        <div className="rows" data-channel-daemon="">
          <div className="row">
            <div className="row-main">
              <div className="row-label">
                <div className="row-title">{state.daemon.title}</div>
              </div>
              <div className="row-control">
                <span className="row-help selectable">{state.daemon.value}</span>
              </div>
            </div>
          </div>
        </div>
      )}
      {/* Other machines that cannot update in place or whose update failed: one row, never a toast each. */}
      {state.machines && state.machines.lines.length > 0 && <MachinesRow machines={state.machines} />}
      {way && <SwitchRow key={`${way.ring}:${way.build}`} way={way} run={run} />}
      {state.tracks.map((track) => (
        <Track
          key={track.ring}
          track={track}
          followed={typeof ring === "string" ? track.ring === ring : track.followed}
          labels={state.labels}
          run={run}
        />
      ))}
    </section>
  );
}
