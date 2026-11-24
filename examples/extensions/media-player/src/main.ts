import {
  Button, cmux, computed, EmptyState, ForEach, HStack, Icon, Image, pane, Panel,
  ProgressView, section, signal, Spacer, Text, VStack, type View
} from "cmux-extension-sdk"

type Track = NonNullable<Awaited<ReturnType<typeof cmux.media.get>>["track"]>
type Timeline = "running" | "paused" | "unknown"
type Command = Parameters<typeof cmux.media.control>[0]
type Layout = "compact" | "card" | "pane"

const labels = cmux.t
const side = { compact: 44, card: 124, pane: 220 }
const timed = (track: Track) => track.position !== undefined && (track.duration ?? 0) > 0

// position is seconds into the track. position_ms is the wall-clock time of that reading.
function position(track: Track, now: number): number {
  const elapsed = track.playing ? Math.max(0, now - track.position_ms) * track.rate / 1000 : 0
  return Math.max(0, Math.min(track.duration ?? Infinity, (track.position ?? 0) + elapsed))
}

function clock(seconds: number): string {
  const whole = Math.floor(seconds)
  const minutes = Math.floor(whole / 60)
  return `${minutes}:${String(whole % 60).padStart(2, "0")}`
}

function player(track: () => Track, layout: Layout, timelineState: Timeline): View {
  const compact = layout === "compact"
  const coverSize = side[layout]
  const [now, setNow] = signal(Date.now())
  if (timelineState === "running") cmux.timer.every(1000, () => setNow(Date.now()))
  const elapsed = computed(() => position(track(), now()))

  const cover = VStack({ alignment: "center" }, [() => {
    const art = track().artwork
    const image = art ? Image(art) : Icon("record.circle").size(coverSize * 0.55).secondary()
    return image.frame({ width: coverSize, height: coverSize }).background(cmux.theme.hover).cornerRadius(compact ? 6 : 12)
  }]).frame({ width: coverSize, height: coverSize })
  const metadata = VStack({ alignment: compact ? "leading" : "center", spacing: 3 }, [
    Text(() => track().title || labels("untitled", "Untitled track"))
      .font(layout === "pane" ? "title" : compact ? "headline" : "title3").weight("semibold").lineLimit(compact ? 1 : 2),
    Text(() => track().artist).font(compact ? "caption" : "subheadline").secondary().lineLimit(1)
  ])

  const [problem, setProblem] = signal("")
  const send = (params: Command) => {
    setProblem("")
    // Call synchronously from the button so the SDK forwards the tap's gesture.
    return cmux.media.control(params).catch((error) => setProblem(error.message))
  }
  const seek = (offset: number) => {
    const t = track()
    if (timed(t)) return send({ command: "seek", seconds: Math.max(0, Math.min(t.duration!, position(t, Date.now()) + offset)) })
  }
  const button = (symbol: string, label: string, tap: () => unknown) =>
    Button(Icon(symbol).size(compact ? 13 : 16), tap).help(label)
  const transport = HStack({ spacing: compact ? 1 : 5 }, [
    Spacer(),
    button("backward.end.fill", labels("previous", "Previous"), () => send({ command: "previous" }))
      .disabled(() => !track().can_previous),
    timelineState !== "unknown" ? button("gobackward.15", labels("back", "Back 15 seconds"), () => seek(-15)) : null,
    Button(Icon(() => track().playing ? "pause.circle.fill" : "play.circle.fill")
      .size(compact ? 23 : 30).color(cmux.theme.accent), () => send({ command: "play_pause" }))
      .help(() => track().playing ? labels("pause", "Pause") : labels("play", "Play")),
    timelineState !== "unknown" ? button("goforward.15", labels("forward", "Forward 15 seconds"), () => seek(15)) : null,
    button("forward.end.fill", labels("next", "Next"), () => send({ command: "next" }))
      .disabled(() => !track().can_next),
    Spacer()
  ])
  const timeLabel = (seconds: () => number) => Text(() => clock(seconds())).font("caption2").monospaced().secondary()
  const timeline = timelineState !== "unknown" ? VStack({ spacing: 4 }, [
    ProgressView(() => elapsed() / track().duration!),
    HStack([timeLabel(elapsed), Spacer(), timeLabel(() => track().duration!)])
  ]) : null
  const body = [
    compact ? HStack({ spacing: 10 }, [cover, metadata.layoutPriority(1)]) :
      VStack({ alignment: "center", spacing: layout === "pane" ? 16 : 8 }, [cover, metadata]),
    timeline, transport, () => problem() ? Text(problem()).font("caption").color(cmux.theme.warning) : null
  ]
  if (layout === "card") return Panel({ style: "card", spacing: 10 }, body)
  if (compact) return VStack({ spacing: 6 }, body).padding(6)
  return VStack({ alignment: "center" }, [
    VStack({ spacing: 16 }, body).frame({ maxWidth: 360 }).padding(16)
  ]).paddingVertical(24)
}

function render(inPane: boolean): View {
  const media = cmux.watch("media.now_playing")
  const rows = computed(() => {
    const track = media.value()?.track
    if (!track || media.error()) return []
    const layout: Layout = inPane ? "pane" : cmux.app.settings().layout === "card" ? "card" : "compact"
    const timeline: Timeline = !timed(track) ? "unknown" : track.playing && track.rate !== 0 ? "running" : "paused"
    return [{ track, layout, timeline }]
  })
  return VStack([
    // Each layout owns its clock. Pausing, losing the timeline or closing the view disposes it.
    ForEach({ items: rows, key: (row) => row.layout + row.timeline },
      (row) => player(() => row().track, row().layout, row().timeline)),
    () => {
      if (rows().length) return null
      const error = media.error()
      if (error) return EmptyState({ symbol: "music.note", title: labels("unavailable", "Media unavailable"), message: error.message })
      if (media.status() === "loading") return ProgressView()
      return EmptyState({ symbol: "music.note", title: labels("empty", "Nothing playing"), message: labels("start", "Play a track or video in cmux.") })
    }
  ])
}

export const renderSection = section(() => render(false))
export const renderPane = pane(() => render(true))
