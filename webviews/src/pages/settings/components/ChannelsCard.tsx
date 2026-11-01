// Settings > Updates' Channels card: every release channel's recent builds from the host's
// `cmux.settings.channels.state` (the feed's notes index, canary verdicts and pulls), read once
// when the card shows. Following tracks the Channel row above it at once. Each build says how it fared, whether this Mac runs or kept it, and links
// to its commit, its PRs and the changes since the installed build; every text is the host's.
// Picking a slower channel the running build is not on shows the way back: Go Back restarts
// once into the build this Mac kept from it (the host's rollback path), or a line says the
// running build stays until that channel passes it. Every other build (older or newer, kept or
// not, never the pulled ones) has a Switch, shown while the pointer is on its row: one restart into
// it, downloaded first unless kept (Leo: "be able to hot swap your dev build for any other dev build").
import { useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useSettingsState, useStore } from "../context";
import { channelsQuery } from "../sectionQueries";
import type { ChannelBuild, ChannelMachines, ChannelSwitch, ChannelTrack, ChannelsState } from "../ops";

function BuildRow({ build, labels }: { build: ChannelBuild; labels: ChannelsState["labels"] }) {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const switchTo = () => {
    setBusy(true);
    setFailure(null);
    void store.channelsSwitchBuild(build.build).then((why) => {
      // Success quits the app into the build; only a refusal comes back.
      setBusy(false);
      setFailure(why);
    });
  };
  return (
    <div className="row channel-build" data-channel-build={build.build} data-health={build.health}>
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
              place, transparent) and nothing moves when it shows. */}
          {build.switch && labels.switch && (
            <button
              type="button"
              className="button channel-switch"
              data-channel-switch-build={build.build}
              data-busy={busy ? "" : undefined}
              disabled={busy}
              onClick={switchTo}
            >
              {labels.switch}
            </button>
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
    </div>
  );
}

function Track({
  track,
  followed,
  labels,
}: {
  track: ChannelTrack;
  followed: boolean;
  labels: ChannelsState["labels"];
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
        <BuildRow key={build.build} build={build} labels={labels} />
      ))}
    </div>
  );
}

function SwitchRow({ way }: { way: ChannelSwitch }) {
  const store = useStore();
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const goBack = (build: string) => {
    setBusy(true);
    setFailure(null);
    void store.channelsGoBack(way.ring, build).then((why) => {
      // Success quits the app into the kept build; only a refusal comes back.
      setBusy(false);
      setFailure(why);
    });
  };
  return (
    <div className="rows" data-channel-switch={way.ring}>
      <div className="row">
        <div className="row-main">
          <div className="row-label">
            <div className="row-help">{way.detail}</div>
            {failure && <div className="row-error">{failure}</div>}
          </div>
          {way.build && way.action && (
            <div className="row-control">
              <button
                type="button"
                className="button"
                data-channel-go-back={way.build}
                disabled={busy}
                onClick={() => way.build && goBack(way.build)}
              >
                {way.action}
              </button>
            </div>
          )}
        </div>
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
                  <button
                    type="button"
                    className="button"
                    data-channel-update-machine={id}
                    disabled={busy !== null}
                    onClick={() => update(id)}
                  >
                    {machines.updateLabel}
                  </button>
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

export function ChannelsCard() {
  const store = useStore();
  // The row's value moves before the host has the write, so the card marks it, not a re-read.
  const ring = useSettingsState().rows.get("updates.channel")?.value;
  const shown = typeof ring === "string" ? ring : undefined;
  // One read per picked channel (the way back depends on it); the route's loader read the current
  // one, and the last answer stays while a new pick's read is out.
  const state = useQuery({ ...channelsQuery(store, shown), placeholderData: keepPreviousData }).data ?? null;
  if (!state) return null;
  return (
    <section className="group" data-card="channels">
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
      {/* Only the picked channel's way back: a read for an earlier pick never offers its button. */}
      {state.switch && (shown === undefined || state.switch.ring === shown) && (
        <SwitchRow key={`${state.switch.ring}:${state.switch.build}`} way={state.switch} />
      )}
      {state.tracks.map((track) => (
        <Track
          key={track.ring}
          track={track}
          followed={typeof ring === "string" ? track.ring === ring : track.followed}
          labels={state.labels}
        />
      ))}
    </section>
  );
}
