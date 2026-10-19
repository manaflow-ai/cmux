// l10n-allow-file: gallery fixtures (sample workspace names and device labels), not shipped UI.
// Sync motion (plans/cmux-next/sync-ux/DESIGN.md part 1): one synced workspace list on a Mac and
// an iPhone at once, replaying a realistic stream (renames, reorders, inserts and removals from a
// second client, a burst, a reconnect snapshot) from schemas/sync-motion/streams.json. Each frame
// is one client: a change made on that device is direct manipulation there (already drawn, no
// motion) and animates on the other. Replay runs the stream again; the gallery's Reduced motion
// control shows the reduced path.
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import streamFile from "../../../schemas/sync-motion/streams.json";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { SyncTitle } from "./SyncTitle";
import { createFrameBatcher, type SyncRow } from "./syncMotion";
import { foldBatch, type SyncStreamEvent, type SyncStreamFile } from "./syncStreams";
import { useSyncListMotion } from "./useSyncListMotion";

const file = streamFile as unknown as SyncStreamFile;

type Device = "mac" | "iphone";
type StageProps = { stream: string; devices: Device[]; long?: boolean };

const CLIENT_OF: Record<Device, string> = { mac: "mac-a", iphone: "phone" };

function initialRows(long: boolean): SyncRow[] {
  if (!long) return file.initial.map((row) => ({ ...row }));
  // A list longer than the frame, for the off-screen rules.
  const extra = Array.from({ length: 24 }, (_, index) => ({ id: `ws_x${index}`, title: `archive ${index + 1}` }));
  return [...file.initial, ...extra];
}

/** One client's list: it receives every event, batched per frame. */
function ClientList({ device, rows, batch }: { device: Device; rows: SyncRow[]; batch: { snapshot: boolean; direct: boolean } }) {
  const list = useRef<HTMLUListElement>(null);
  const motion = useSyncListMotion(list, rows, batch);
  return (
    <ul ref={list} className={`sm-list sm-list-${device}`} data-sync-list="" aria-label="Workspaces">
      {motion.items.map(({ row, exiting }) => (
        <li
          key={row.id}
          className="sm-row"
          data-sync-id={row.id}
          data-sync-exiting={exiting ? "true" : undefined}
          aria-hidden={exiting || undefined}
        >
          <span className="sm-dot" />
          <SyncTitle className="sm-title" text={row.title} animate={motion.renames(row.id)} />
        </li>
      ))}
    </ul>
  );
}

function useClient(device: Device, stream: string, long: boolean, run: number) {
  const [state, setState] = useState(() => ({ rows: initialRows(long), snapshot: false, direct: false }));
  const [done, setDone] = useState(false);
  useEffect(() => {
    setState({ rows: initialRows(long), snapshot: true, direct: false });
    setDone(false);
    const events = file.streams.find((candidate) => candidate.name === stream)?.events ?? [];
    const client = CLIENT_OF[device];
    let pending = events.length;
    const batcher = createFrameBatcher<SyncStreamEvent>((batch) => {
      setState((current) => foldBatch(current.rows, batch, client));
      pending -= batch.length;
      if (pending === 0) setDone(true);
    });
    // Fixture playback: each event arrives at its recorded offset (the gallery's intentional delay).
    const timers = events.map((event) => setTimeout(() => batcher.push(event), event.at));
    if (events.length === 0) setDone(true);
    return () => timers.forEach(clearTimeout);
  }, [device, stream, long, run]);
  return { state, done };
}

function MacFrame({ children, label }: { children: ReactNode; label: string }) {
  return (
    <figure className="sm-mac" aria-label={label}>
      <div className="sm-mac-titlebar">
        <span className="sm-light" />
        <span className="sm-light" />
        <span className="sm-light" />
        <span className="sm-mac-name">{label}</span>
      </div>
      <div className="sm-mac-body">
        <aside className="sm-mac-sidebar">{children}</aside>
        <div className="sm-mac-content" />
      </div>
    </figure>
  );
}

function PhoneFrame({ children, label }: { children: ReactNode; label: string }) {
  return (
    <figure className="sm-phone" aria-label={label}>
      <div className="sm-phone-island" />
      <div className="sm-phone-header">Workspaces</div>
      <div className="sm-phone-body">{children}</div>
    </figure>
  );
}

function Device({ device, stream, long, run, onDone }: StageProps & { device: Device; run: number; onDone(d: Device, v: boolean): void }) {
  const { state, done } = useClient(device, stream, Boolean(long), run);
  useEffect(() => onDone(device, done), [device, done, onDone]);
  const name = file.clients.find((client) => client.id === CLIENT_OF[device])?.device_name ?? device;
  const list = <ClientList device={device} rows={state.rows} batch={state} />;
  return device === "mac" ? <MacFrame label={name}>{list}</MacFrame> : <PhoneFrame label={name}>{list}</PhoneFrame>;
}

function SyncMotionStage({ stream, devices, long }: StageProps) {
  const [run, setRun] = useState(0);
  const [finished, setFinished] = useState<Record<string, boolean>>({});
  const onDone = useMemo(() => (device: Device, value: boolean) => setFinished((current) => (current[device] === value ? current : { ...current, [device]: value })), []);
  const allDone = devices.every((device) => finished[device]);
  const note = file.streams.find((candidate) => candidate.name === stream)?.note;
  return (
    <div className="sm-stage" data-sync-done={allDone ? "true" : "false"}>
      <div className="sm-toolbar">
        <button type="button" className="sm-replay" onClick={() => setRun((value) => value + 1)}>
          Replay
        </button>
        <span className="sm-note">{note}</span>
      </div>
      <div className="sm-devices">
        {devices.map((device) => (
          <Device key={device} device={device} stream={stream} long={long} devices={devices} run={run} onDone={onDone} />
        ))}
      </div>
    </div>
  );
}

const replay: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".sm-stage[data-sync-done=true]"), { capMs: 6000 });
  await ctx.click({ role: "button", name: "Replay" });
  await ctx.waitFor(() => ctx.document.querySelector(".sm-stage[data-sync-done=true]"), { capMs: 6000 });
};

const both: Device[] = ["mac", "iphone"];

export default componentEntry<StageProps>({
  id: "motion.sync-list",
  title: "Synced list motion (Mac + iPhone)",
  area: "Sync UX",
  height: 640,
  widths: { narrow: 720, normal: 900, wide: 1200 },
  covers: [
    "motion/syncMotion.ts",
    "motion/useSyncListMotion.ts#useSyncListMotion",
    "motion/SyncTitle.tsx#SyncTitle",
    "motion/syncStreams.ts",
  ],
  load: async () => SyncMotionStage,
  styles: () => import("./syncMotion.gallery.css"),
  variants: {
    "renames-from-another-mac": { props: { stream: "renames-from-another-mac", devices: both }, play: replay },
    "reorder-from-iphone": { props: { stream: "reorder-from-iphone", devices: both }, play: replay },
    "inserts-from-second-client": { props: { stream: "inserts-from-second-client", devices: both }, play: replay },
    "burst-batched": { props: { stream: "burst-batched", devices: both }, play: replay },
    "reconnect-snapshot": { props: { stream: "reconnect-snapshot", devices: both }, play: replay },
    "long-list-offscreen": { props: { stream: "burst-batched", devices: both, long: true }, play: replay },
  },
});
