// Pieces both variants share: the user actions, the list of running
// assertions with Stop, the notices, and the state when the host cannot
// keep the Mac awake.

import { assertionDetail, assertionTitle, durationWords, releaseText, timeLeftText } from "../format.ts"
import { t } from "../l10n.ts"
import type { Assertion } from "../model.ts"
import { soonestEnd } from "../model.ts"
import { presetRequest, type Preset, type StartOptions } from "../presets.ts"
import { actionError, active, create, dismissRelease, now, power, problem, release, releaseAll, setActionError, status } from "../store.ts"
import { busy, loadTerminals, terminalsState } from "../terminals.ts"

export type Actions = { show: () => unknown }

/** Starts a preset from a user event. The gesture is read before any await. */
export function startPreset(preset: Preset, options: StartOptions = {}): void {
  const gesture = cmux.gesture()
  const r = presetRequest(preset, options)
  if (!r.ok) {
    setActionError(r.message)
    return
  }
  void create(r.params, { gesture })
}

export function stopOne(id: string): void {
  void release(id, { gesture: cmux.gesture() })
}

/** Stops every running assertion this person may stop. */
export function stopAll(): void {
  void releaseAll({ gesture: cmux.gesture() })
}

export const isOn = () => active().length > 0
export const CUP = () => (isOn() ? "cup.and.saucer.fill" : "cup.and.saucer")

/** "42m" for the soonest timed end; null when nothing is timed. */
export function soonestText(): string | null {
  const end = soonestEnd(active())
  return end === null ? null : timeLeftText(end - now())
}

export const UNTIL_SYMBOL = (a: Assertion) => (a.until ? "terminal" : a.expiresAt !== null ? "timer" : "infinity")

function activeRow(a: () => Assertion) {
  return HStack({ spacing: 0 }, [
    Row({
      title: () => assertionTitle(a()),
      subtitle: () => assertionDetail(a(), now(), false),
      symbol: () => UNTIL_SYMBOL(a()),
      badge: () => (a().expiresAt === null ? null : timeLeftText(a().expiresAt! - now()))
    }).layoutPriority(1),
    Button(t("action.stop", "Stop"), () => stopOne(a().id))
      .font("callout")
      .help(t("action.stop.help", "Let the Mac sleep as usual again"))
      .padding({ trailing: 10 })
  ]).contextMenu(() => [Button(t("action.stop", "Stop"), () => stopOne(a().id))])
}

/** Running assertions with time left and Stop. */
export function ActiveList() {
  return VStack({ spacing: 2 }, [ForEach({ items: active, key: (a) => a.id }, (a) => activeRow(a))])
}

/** One line about an assertion that ended on its own (timeout, command finished, app turned off). */
export function NoticeLine() {
  return VStack({ spacing: 0 }, [
    () => {
      const r = power().lastRelease
      if (!r) return null
      return HStack({ spacing: 6 }, [
        Icon("checkmark.circle").size(11).color("secondary"),
        Text(releaseText(r.cause, r.title)).font("caption").secondary().lineLimit(2),
        Spacer(),
        Button(t("action.dismiss", "Dismiss"), dismissRelease).font("caption")
      ]).padding({ top: 4, leading: 14, bottom: 4, trailing: 12 })
    }
  ])
}

export function ErrorLine() {
  return VStack({ spacing: 0 }, [
    () => {
      const e = actionError()
      if (!e) return null
      return HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").size(11).color("warning"), Text(e).font("caption").color("warning").lineLimit(3)]).padding({ top: 4, leading: 14, bottom: 4, trailing: 12 })
    }
  ])
}

type ProblemSpec = { title: string; message: string; symbol: string } | null

/** What to show instead of the controls, or null when the host can keep the Mac awake. */
export function problemSpec(): ProblemSpec {
  const s = status()
  const p = problem()
  if (s === "ready" || s === "loading") return null
  if (s === "denied")
    return { title: t("denied.title", "No permission to keep the Mac awake"), message: t("denied.message", "Allow {scope} in Settings > Apps > Caffeinate.", { scope: p?.scope ?? "power:write" }), symbol: "lock" }
  if (s === "unavailable") {
    if (p?.code === "power.unsupported_platform") return { title: t("platform.title", "Only on a Mac"), message: t("platform.message", "This computer cannot hold Mac power assertions."), symbol: "desktopcomputer" }
    return { title: t("unavailable.title", "Keeping awake is not available"), message: t("unavailable.message", "This cmux build cannot hold power assertions yet ({op}).", { op: "power.assertion.create" }), symbol: "cup.and.saucer" }
  }
  return { title: t("error.title", "Cannot read power assertions"), message: p?.message || p?.code || "", symbol: "exclamationmark.triangle" }
}

const specKey = computed(() => JSON.stringify(problemSpec()))

/** The problem state as an EmptyState, rebuilt only when it changes. */
export function ProblemView() {
  return VStack({ spacing: 0 }, [
    () => {
      const spec = JSON.parse(specKey()) as ProblemSpec
      return spec ? EmptyState(spec) : null
    }
  ])
}

export const hasProblem = computed(() => problemSpec() !== null)

/** "While a Command Runs" submenu: one item per terminal running a command, and Refresh. */
export function commandMenuItems(): ReturnType<typeof Button>[] {
  const s = terminalsState()
  const items: ReturnType<typeof Button>[] = []
  if (s === "denied") items.push(Button(t("terminals.denied", "Allow terminal:read to pick a terminal")).disabled())
  else if (s === "unavailable") items.push(Button(t("terminals.unavailable", "Terminals are not available")).disabled())
  else if (s === "loading" && busy().length === 0) items.push(Button(t("loading", "Loading…")).disabled())
  else if (busy().length === 0) items.push(Button(t("terminals.none", "No command is running")).disabled())
  for (const b of busy()) items.push(Button(b.label, () => startPreset("command", { terminal: b.terminal, label: b.label })))
  items.push(Divider() as ReturnType<typeof Button>, Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()))
  return items
}

export const durationLabel = (minutes: number) => t("menu.for", "For {duration}", { duration: durationWords(minutes) })
