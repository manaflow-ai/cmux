// Variant "pane": pane first. The pane explains each option in plain words
// (with its `caffeinate` flag) and lets the user combine them: what stays
// awake, for how long, and what ends it early (a terminal's command or a
// process). The status item is a cup that opens the pane; right-click shows
// Stop per assertion.

import { assertionTitle, timeLeftText } from "../format.ts"
import { FLAG, KINDS, kindExplanation, kindTitle, type Kind } from "../kinds.ts"
import { t } from "../l10n.ts"
import { presetRequest, type Preset, type StartOptions } from "../presets.ts"
import { active, now, power } from "../store.ts"
import { busy, loadTerminals, terminalsState } from "../terminals.ts"
import { ActiveList, CUP, ErrorLine, hasProblem, isOn, NoticeLine, ProblemView, soonestText, startPreset, stopAll, stopOne, type Actions } from "./parts.ts"

type Duration = "untilStopped" | 15 | 60 | 120 | "custom"
type End = "time" | "command" | "process"

const [kinds, setKinds] = signal<Kind[]>(["display", "idle"])
const [duration, setDuration] = signal<Duration>(60)
const [customMinutes, setCustomMinutes] = signal("")
const [end, setEnd] = signal<End>("time")
const [terminal, setTerminal] = signal<string | null>(null)
const [pid, setPid] = signal("")

const toggleKind = (k: Kind) => setKinds((list) => (list.includes(k) ? list.filter((x) => x !== k) : KINDS.filter((x) => x === k || list.includes(x))))

/** The pane's choices as a preset plus options (the same mapping the commands use). */
export function choiceRequest(): { preset: Preset; options: StartOptions } {
  const d = duration()
  const minutes = d === "custom" ? customMinutes() : d === "untilStopped" ? undefined : d
  const options: StartOptions = { kinds: kinds() }
  if (end() === "command") {
    const term = terminal()
    const label = busy().find((b) => b.terminal === term)?.label
    return { preset: "command", options: { ...options, terminal: term ?? undefined, label, minutes } }
  }
  if (end() === "process") return { preset: "command", options: { ...options, pid: pid(), minutes } }
  return d === "untilStopped" ? { preset: "untilStopped", options } : { preset: "duration", options: { ...options, minutes } }
}

const canStart = computed(() => {
  const c = choiceRequest()
  return presetRequest(c.preset, c.options).ok
})

function header(text: string) {
  return Text(text).font("caption").weight("semibold").secondary().padding({ top: 12, leading: 14, bottom: 4, trailing: 12 })
}

function chip(label: string, selected: () => boolean, onTap: () => void, help?: string) {
  const v = Text(label)
    .font("callout")
    .lineLimit(1)
    .fixedSize("horizontal")
    .paddingHorizontal(9)
    .paddingVertical(3)
    .background(() => (selected() ? "selected" : null))
    .hoverBackground("hover")
    .borderColor("separator")
    .borderWidth(1)
    .cornerRadius(7)
    .cursor("pointer")
    .onTap(onTap)
  return help ? v.help(help) : v
}

/** One option with its explanation (Row subtitles are one line; README gap 8). */
function kindOption(k: Kind) {
  const on = () => kinds().includes(k)
  return HStack({ spacing: 10 }, [
    Icon(() => (on() ? "checkmark.circle.fill" : "circle"))
      .size(14)
      .color(() => (on() ? "accent" : "tertiary")),
    VStack({ spacing: 1 }, [Text(kindTitle(k)).font("body"), Text(kindExplanation(k)).font("caption").secondary().lineLimit(4)])
      .frame({ maxWidth: "infinity" })
      .layoutPriority(1),
    Text(FLAG[k]).font("caption").monospaced().color("tertiary")
  ])
    .padding({ top: 5, leading: 14, bottom: 5, trailing: 12 })
    .background(() => (on() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(8)
    .paddingHorizontal(6)
    .cursor("pointer")
    .onTap(() => toggleKind(k))
}

function durationChoices() {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      chip(t("choice.untilStopped", "Until stopped"), () => duration() === "untilStopped", () => setDuration("untilStopped")),
      chip(timeLeftText(15 * 60_000), () => duration() === 15, () => setDuration(15)),
      chip(timeLeftText(60 * 60_000), () => duration() === 60, () => setDuration(60)),
      chip(timeLeftText(120 * 60_000), () => duration() === 120, () => setDuration(120)),
      chip(t("choice.custom", "Other"), () => duration() === "custom", () => setDuration("custom"), t("choice.custom.help", "Set minutes (-t)")),
      Spacer()
    ]),
    () =>
      duration() === "custom"
        ? TextField(customMinutes, { placeholder: t("field.minutes", "Minutes"), onEdit: setCustomMinutes, onSubmit: setCustomMinutes }).frame({ maxWidth: 140 })
        : null
  ]).padding({ leading: 14, trailing: 12, bottom: 2 })
}

function terminalChoices() {
  return VStack({ spacing: 0 }, [
    () => {
      const s = terminalsState()
      const list = busy()
      if (!list.length) {
        const text = s === "denied" ? t("terminals.denied", "Allow terminal:read to pick a terminal") : s === "loading" ? t("loading", "Loading…") : t("terminals.none", "No command is running")
        return Text(text).font("caption").secondary().padding({ top: 4, leading: 20, bottom: 2, trailing: 12 })
      }
      return VStack(
        { spacing: 0 },
        list.map((b) => Row({ title: b.label, symbol: "terminal", selected: () => terminal() === b.terminal, accessory: () => (terminal() === b.terminal ? "checkmark" : null) }).cursor("pointer").onTap(() => setTerminal(b.terminal)))
      )
    },
    HStack({ spacing: 0 }, [Spacer(), Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()).font("caption")]).padding({ trailing: 12, top: 2 })
  ])
}

function endChoices() {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      chip(t("end.time", "Never"), () => end() === "time", () => setEnd("time")),
      chip(
        t("end.command", "Command ends"),
        () => end() === "command",
        () => {
          setEnd("command")
          void loadTerminals()
        }
      ),
      chip(t("end.process", "Process exits"), () => end() === "process", () => setEnd("process"), t("end.process.help", "Enter a process ID (-w)")),
      Spacer()
    ]).padding({ leading: 14, trailing: 12 }),
    () => (end() === "command" ? terminalChoices() : null),
    () =>
      end() === "process"
        ? TextField(pid, { placeholder: t("field.pid", "Process ID"), onEdit: setPid, onSubmit: setPid })
            .frame({ maxWidth: 160 })
            .padding({ leading: 14 })
        : null
  ])
}

function startButton() {
  return HStack({ spacing: 8 }, [
    Spacer(),
    Button(t("action.start", "Keep Awake"), () => {
      const c = choiceRequest()
      startPreset(c.preset, c.options)
    })
      .disabled(() => !canStart())
      .font("body")
  ]).padding({ top: 10, leading: 14, bottom: 4, trailing: 14 })
}

export function paneStatus(actions: Actions) {
  return HStack({ spacing: 3 }, [
    Icon(CUP)
      .size(12)
      .color(() => (isOn() ? "accent" : "secondary")),
    Text(() => (isOn() ? (soonestText() ?? "") : "")).font("caption").monospaced()
  ])
    .cursor("pointer")
    .help(() => (isOn() ? t("status.help.on", "Keeping the Mac awake") : t("status.help.off", "Caffeinate: the Mac sleeps as usual")))
    .onTap(actions.show)
    .contextMenu(() => {
      const items: ReturnType<typeof Button>[] = active().map((a) => {
        const left = a.expiresAt === null ? null : timeLeftText(a.expiresAt - now())
        const title = assertionTitle(a)
        return Button(left ? t("menu.stopTimed", "Stop: {title} ({left} left)", { title, left }) : t("menu.stop", "Stop: {title}", { title }), () => stopOne(a.id))
      })
      if (items.length > 1) items.push(Button(t("action.stopAll", "Stop All"), stopAll).destructive())
      if (!items.length) items.push(Button(t("preset.untilStopped", "Keep Awake Until Stopped"), () => startPreset("untilStopped")))
      items.push(Divider() as ReturnType<typeof Button>, Button(t("menu.open", "Open Caffeinate"), actions.show))
      return items
    })
}

export function panePane() {
  return VStack({ spacing: 0 }, [
    () =>
      hasProblem()
        ? ProblemView()
        : VStack({ spacing: 0 }, [
            header(t("section.what", "Keep awake")),
            VStack({ spacing: 2 }, KINDS.map(kindOption)),
            header(t("section.howLong", "For how long")),
            durationChoices(),
            header(t("section.end", "End early when")),
            endChoices(),
            startButton(),
            ErrorLine(),
            NoticeLine(),
            Divider().padding({ top: 8 }),
            header(t("section.running", "Running")),
            () => (power().assertions.length === 0 || active().length === 0 ? Text(t("pane.off", "The Mac sleeps as usual")).font("caption").secondary().padding({ leading: 14, bottom: 10 }) : null),
            ActiveList(),
            () => (active().length > 1 ? HStack({ spacing: 0 }, [Spacer(), Button(t("action.stopAll", "Stop All"), stopAll).font("callout")]).padding({ top: 4, trailing: 14, bottom: 8 }) : null)
          ])
  ])
}
