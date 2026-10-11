// Pieces every view shares: status glyphs, version lines, the action button
// of one CLI on one machine, account lines, install hints, errors, toolbar.

import { install, refresh, signIn, update } from "../actions.ts"
import { type Account, type CliEntry, levelOf, type Machine, safeLabel, showsAccounts, statusOf, type Status } from "../model/entries.ts"
import type { UpdateLevel } from "../model/version.ts"
import { busy, type Job } from "../model/jobs.ts"
import { displayName, hintsFor, type InstallHint, platformOf } from "../model/providers.ts"
import { shortVersion } from "../model/version.ts"
import { t } from "../l10n.ts"
import type { OpError } from "../ops.ts"
import { byMachine, jobOf, machines } from "../store.ts"

export const nameOf = (e: CliEntry) => displayName(e.cli, e.name)

export function machineName(m: Machine): string {
  if (!m.id) return t("machine.this", "This Mac")
  return m.name || m.id
}

export function statusSymbol(s: Status): string {
  switch (s) {
    case "current":
      return "checkmark.circle.fill"
    case "update":
      return "arrow.up.circle.fill"
    case "missing":
      return "circle.dashed"
    case "ahead":
      return "hammer.circle"
    default:
      return "questionmark.circle"
  }
}

export function statusTone(s: Status): string {
  return s === "current" ? "success" : s === "update" ? "warning" : "tertiary"
}

/** "2.1.281", "2.1.281 → 2.1.290", "Not installed". */
export function versionLine(e: CliEntry): string {
  const s = statusOf(e)
  if (s === "missing") return t("version.missing", "Not installed")
  const v = shortVersion(e.version) || t("version.unknown", "Unknown version")
  if (s === "update") return t("version.update", "{current} → {latest}", { current: v, latest: shortVersion(e.latest!.version) })
  if (s === "current") return t("version.current", "{version}, up to date", { version: v })
  if (s === "ahead") return t("version.ahead", "{version}, newer than the release", { version: v })
  return v
}

export function levelBadge(e: CliEntry) {
  return statusOf(e) === "update" ? badgeFor(levelOf(e)) : null
}

export function badgeFor(level: UpdateLevel | null) {
  if (!level || level === "none" || level === "newer" || level === "unknown") return null
  const text = level === "major" ? t("level.major", "Major") : level === "minor" ? t("level.minor", "Minor") : t("level.patch", "Patch")
  return Badge(text, level === "major" ? "danger" : "warning").fixedSize()
}

export function jobText(j: Job): string {
  switch (j.phase) {
    case "requested":
      return t("job.requested", "Asking cmux…")
    case "running":
      return j.kind === "update" ? t("job.updating", "Updating in a terminal…") : j.kind === "install" ? t("job.installing", "Installing in a terminal…") : t("job.signingIn", "Signing in in a terminal…")
    case "succeeded":
      return t("job.done", "Done")
    case "failed":
      return j.exitCode !== null ? t("job.failedCode", "Failed (exit {code})", { code: j.exitCode }) : t("job.failed", "Failed")
    case "refused":
      return refusalText(j.error)
  }
}

export function refusalText(code: string | null): string {
  if (code === "scope.missing") return t("refused.scope", "Allow this app to run commands in Settings > Apps")
  if (code === "operation.unsupported") return t("refused.unsupported", "This cmux cannot run it yet")
  return t("refused.other", "cmux did not run it ({code})", { code: code ?? "" })
}

/** The one action a CLI row offers on a machine, or the job's state while it runs. */
export function primaryAction(machine: string, e: () => CliEntry) {
  return () => {
    const entry = e()
    const j = jobOf(machine, entry.cli)
    if (j && (busy(j) || j.phase === "failed" || j.phase === "refused")) {
      const retry = !busy(j)
      return HStack({ spacing: 6 }, [
        busy(j) ? ProgressView(null).frame({ width: 12, height: 12 }) : Icon("exclamationmark.triangle.fill").font("caption").color("warning"),
        Text(jobText(j)).font("caption").secondary().lineLimit(2),
        retry ? Button(t("action.retry", "Try Again"), () => void again(machine, entry, j)).font("caption") : null
      ])
    }
    const s = statusOf(entry)
    if (s === "update") {
      if (!entry.updatable) return Text(t("update.manual", "Update it the way you installed it")).font("caption").secondary().lineLimit(2)
      return Button(t("action.update", "Update"), () => void update(machine, entry.cli)).font("caption")
    }
    if (s === "missing") {
      const hint = firstHint(machine, entry.cli)
      if (!hint || hint.method === "cmux") return null
      return Button(t("action.install", "Install…"), () => void install(machine, entry.cli, hint.method)).font("caption")
    }
    return null
  }
}

function again(machine: string, entry: CliEntry, j: Job) {
  if (j.kind === "update") return update(machine, entry.cli)
  if (j.kind === "sign_in") return signIn(machine, entry.cli)
  const hint = firstHint(machine, entry.cli)
  return hint ? install(machine, entry.cli, hint.method) : undefined
}

const platformFor = (machine: string) => platformOf(machines().find((m) => m.id === machine)?.os)

export const firstHint = (machine: string, cli: string): InstallHint | null => hintsFor(cli, platformFor(machine))[0] ?? null

export function accountStatusText(a: Account): string {
  switch (a.status) {
    case "signed_in":
      return t("account.signedIn", "Signed in")
    case "expired":
      return t("account.expired", "Sign-in expired")
    case "missing":
      return t("account.missing", "Signed out")
    default:
      return t("account.unknown", "Sign-in unknown")
  }
}

/** One line per account: label, plan, state, and Sign In when it is needed. */
export function accountLines(machine: string, e: () => CliEntry) {
  return () => {
    const entry = e()
    if (!showsAccounts(entry)) return null
    const list = entry.accounts.length ? entry.accounts : [{ account: "", label: "", status: "missing" as const }]
    return VStack({ spacing: 3 }, list.map((a) => accountLine(machine, entry, a)))
  }
}

function accountLine(machine: string, entry: CliEntry, a: Account) {
  const label = [safeLabel(a.label), a.plan ? safeLabel(a.plan) : null].filter(Boolean).join(" · ")
  const bad = a.status === "expired" || a.status === "missing"
  return HStack({ spacing: 6 }, [
    Icon(bad ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle").font("caption").color(bad ? "warning" : "secondary"),
    Text(label ? `${label} · ${accountStatusText(a)}` : accountStatusText(a)).font("caption").secondary().lineLimit(1).truncation("tail"),
    Spacer(),
    bad && !busy(jobOf(machine, entry.cli)) ? Button(t("action.signIn", "Sign In…"), () => void signIn(machine, entry.cli)).font("caption") : null
  ])
}

/** Install commands as text (the host runs them only through Install…). */
export function hintLines(machine: string, cli: string) {
  const hints = hintsFor(cli, platformFor(machine))
  if (!hints.length) return Text(t("hint.none", "No install hint for this CLI")).font("caption").secondary()
  return VStack(
    { spacing: 2 },
    hints.map((h) =>
      h.method === "cmux" ? Text(t("hint.cmux", "Comes with cmux")).font("caption").secondary() : Text(h.command).font(11).monospaced().secondary().lineLimit(1).truncation("middle")
    )
  )
}

export function errorState(err: OpError) {
  if (err.missing) {
    return EmptyState({
      title: t("error.missingTitle", "Agent CLI detection is not available yet"),
      message: t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }),
      symbol: "puzzlepiece.extension"
    })
  }
  return EmptyState({ title: t("error.load", "Cannot list agent CLIs"), message: err.message, symbol: "exclamationmark.triangle" })
}

/** Title, a one-line summary and Refresh (checks latest versions again). */
export function toolbar(summary: () => string) {
  return HStack({ spacing: 8 }, [
    VStack({ spacing: 1 }, [Text(t("title", "Agent CLIs")).font("headline"), Text(summary).font("caption").secondary().lineLimit(1)]),
    Spacer(),
    Button(Icon("arrow.clockwise"), () => void refresh()).help(t("action.refresh", "Check for Updates"))
  ]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 })
}

/** Every machine's entries, in machine order, for summaries. */
export const allLists = () => machines().map((m) => byMachine()[m.id]?.entries ?? [])
