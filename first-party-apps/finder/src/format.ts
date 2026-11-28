// Size, date and count formatting without Intl (QuickJS may lack it), with
// localized words from the string tables.

import { t } from "./l10n.ts"
import type { Entry, KindGroup } from "./model/entries.ts"
import { kindGroup } from "./model/entries.ts"

export function formatBytes(n: number | null | undefined): string {
  if (n === null || n === undefined) return "—"
  if (n < 1000) return t("size.bytes", "{n} bytes", { n })
  const units = ["KB", "MB", "GB", "TB"]
  let v = n / 1000
  let i = 0
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000
    i++
  }
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`
}

export function formatCount(n: number): string {
  return String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

const pad = (n: number) => String(n).padStart(2, "0")

export function formatDate(ms: number | null | undefined, now: number = Date.now()): string {
  if (ms === null || ms === undefined) return "—"
  const d = new Date(ms)
  const n = new Date(now)
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  if (d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()) return t("date.today", "Today {time}", { time })
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`
}

export function formatDuration(seconds: number): string {
  if (seconds < 60) return t("duration.seconds", "{n} s left", { n: seconds })
  const m = Math.ceil(seconds / 60)
  return m < 60 ? t("duration.minutes", "{n} min left", { n: m }) : t("duration.hours", "{n} h left", { n: Math.ceil(m / 60) })
}

export function kindLabel(group: KindGroup): string {
  switch (group) {
    case "folder":
      return t("kind.folder", "Folder")
    case "text":
      return t("kind.text", "Text")
    case "markdown":
      return t("kind.markdown", "Markdown")
    case "code":
      return t("kind.code", "Source code")
    case "image":
      return t("kind.image", "Image")
    case "pdf":
      return t("kind.pdf", "PDF document")
    case "archive":
      return t("kind.archive", "Archive")
    case "media":
      return t("kind.media", "Media")
    default:
      return t("kind.other", "Document")
  }
}

export function symbolFor(e: Entry): string {
  if (e.kind === "symlink") return e.target_kind === "dir" ? "folder.badge.questionmark" : "arrow.up.right.square"
  switch (kindGroup(e)) {
    case "folder":
      return "folder"
    case "markdown":
    case "text":
      return "doc.text"
    case "code":
      return "chevron.left.forwardslash.chevron.right"
    case "image":
      return "photo"
    case "pdf":
      return "doc.richtext"
    case "archive":
      return "archivebox"
    case "media":
      return "play.rectangle"
    default:
      return "doc"
  }
}
