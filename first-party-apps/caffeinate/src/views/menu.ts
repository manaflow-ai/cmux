// Variant "menu" (recommended): menu-bar first. The status item shows a cup
// (filled while something keeps the Mac awake) and the soonest time left; a
// click opens a dropdown with the presets, a duration submenu, a submenu of
// running commands, and Stop per assertion. The pane is a short list:
// what runs now, and the presets as rows.

import { assertionTitle, timeLeftText } from "../format.ts"
import { kindsText } from "../kinds.ts"
import { t } from "../l10n.ts"
import { DEFAULT_KINDS, DURATIONS } from "../presets.ts"
import { active, now } from "../store.ts"
import { busy, loadTerminals, terminalsState } from "../terminals.ts"
import { ActiveList, commandMenuItems, CUP, durationLabel, ErrorLine, hasProblem, isOn, NoticeLine, problemSpec, ProblemView, soonestText, startPreset, stopAll, stopOne, type Actions } from "./parts.ts"

const glance = () => (hasProblem() ? "—" : isOn() ? (soonestText() ?? t("glance.on", "On")) : t("glance.off", "Off"))

function menuItems(actions: Actions) {
  const items: ReturnType<typeof Button>[] = []
  const spec = problemSpec()
  const list = active()
  if (spec) items.push(Button(spec.title).disabled())
  else items.push(Button(list.length ? t("menu.header.on", "Keeping the Mac awake ({n})", { n: list.length }) : t("menu.header.off", "The Mac sleeps as usual")).disabled())
  items.push(
    Divider() as ReturnType<typeof Button>,
    Button(t("preset.untilStopped", "Keep Awake Until Stopped"), () => startPreset("untilStopped")).disabled(!!spec),
    Button(t("preset.hour", "Keep Awake for 1 Hour"), () => startPreset("hour")).disabled(!!spec),
    Menu(
      t("menu.forSubmenu", "Keep Awake For"),
      DURATIONS.filter((m) => m !== 60).map((m) => Button(durationLabel(m), () => startPreset("duration", { minutes: m })))
    ).disabled(!!spec),
    Menu(t("menu.commandSubmenu", "Keep Awake While a Command Runs"), commandMenuItems()).disabled(!!spec)
  )
  if (list.length) {
    items.push(Divider() as ReturnType<typeof Button>)
    for (const a of list) {
      const left = a.expiresAt === null ? null : timeLeftText(a.expiresAt - now())
      const title = assertionTitle(a)
      items.push(Button(left ? t("menu.stopTimed", "Stop: {title} ({left} left)", { title, left }) : t("menu.stop", "Stop: {title}", { title }), () => stopOne(a.id)))
    }
    if (list.length > 1) items.push(Button(t("action.stopAll", "Stop All"), stopAll).destructive())
  }
  items.push(Divider() as ReturnType<typeof Button>, Button(t("menu.show", "Show Caffeinate"), actions.show))
  return items
}

export function menuStatus(actions: Actions) {
  return HStack({ spacing: 3 }, [
    Icon(CUP)
      .size(12)
      .color(() => (isOn() ? "accent" : "secondary")),
    Menu(glance, []).contextMenu(() => menuItems(actions))
  ]).help(() => (isOn() ? t("status.help.on", "Keeping the Mac awake") : t("status.help.off", "Caffeinate: the Mac sleeps as usual")))
}

const [commandsOpen, setCommandsOpen] = signal(false)

function presetRow(title: string, subtitle: string, symbol: string, run: () => void) {
  return Row({ title, subtitle, symbol }).cursor("pointer").onTap(run)
}

function commandRows() {
  return VStack({ spacing: 0 }, [
    () => {
      if (!commandsOpen()) return null
      const s = terminalsState()
      const rows = busy().map((b) => Row({ title: b.label, symbol: "terminal", accessory: "play.fill" }).cursor("pointer").onTap(() => startPreset("command", { terminal: b.terminal, label: b.label })))
      const empty = s === "denied" ? t("terminals.denied", "Allow terminal:read to pick a terminal") : s === "loading" ? t("loading", "Loading…") : t("terminals.none", "No command is running")
      return VStack({ spacing: 0 }, [
        ...(rows.length ? rows : [Text(empty).font("caption").secondary().padding({ top: 2, leading: 34, bottom: 4, trailing: 12 })]),
        HStack({ spacing: 0 }, [Spacer(), Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()).font("caption")]).padding({ trailing: 12, bottom: 4 })
      ])
    }
  ])
}

function startList() {
  return VStack({ spacing: 0 }, [
    Text(t("pane.start", "Keep awake")).font("caption").weight("semibold").secondary().padding({ top: 10, leading: 14, bottom: 4, trailing: 12 }),
    presetRow(t("preset.untilStopped.short", "Until I stop it"), kindsText(DEFAULT_KINDS.untilStopped), "infinity", () => startPreset("untilStopped")),
    presetRow(t("preset.hour.short", "For 1 hour"), kindsText(DEFAULT_KINDS.hour), "timer", () => startPreset("hour")),
    HStack({ spacing: 6 }, [
      ...DURATIONS.filter((m) => m !== 60).map((m) =>
        Text(timeLeftText(m * 60_000))
          .font("callout")
          .paddingHorizontal(8)
          .paddingVertical(3)
          .background("hover")
          .cornerRadius(6)
          .cursor("pointer")
          .help(durationLabel(m))
          .onTap(() => startPreset("duration", { minutes: m }))
      ),
      Spacer()
    ]).padding({ top: 2, leading: 40, bottom: 6, trailing: 12 }),
    Row({ title: t("preset.command.short", "While a command runs"), subtitle: kindsText(DEFAULT_KINDS.command), symbol: "terminal", accessory: () => (commandsOpen() ? "chevron.down" : "chevron.right") })
      .cursor("pointer")
      .onTap(() => {
        const open = !commandsOpen()
        setCommandsOpen(open)
        if (open) void loadTerminals()
      }),
    commandRows()
  ])
}

export function menuPane() {
  return VStack({ spacing: 0 }, [
    () =>
      hasProblem()
        ? ProblemView()
        : VStack({ spacing: 0 }, [
            HStack({ spacing: 8 }, [
              Icon(CUP)
                .size(16)
                .color(() => (isOn() ? "accent" : "secondary")),
              Text(() => (isOn() ? t("pane.on", "Keeping the Mac awake") : t("pane.off", "The Mac sleeps as usual")))
                .font("headline")
                .lineLimit(2)
                .layoutPriority(1),
              Spacer(),
              () => (active().length > 1 ? Button(t("action.stopAll", "Stop All"), stopAll).font("callout") : null)
            ]).padding({ top: 12, leading: 14, bottom: 6, trailing: 12 }),
            ActiveList(),
            NoticeLine(),
            ErrorLine(),
            Divider().padding({ top: 6, bottom: 2 }),
            startList()
          ])
  ])
}
