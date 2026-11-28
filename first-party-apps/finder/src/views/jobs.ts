// File operations in progress: progress, cancel, conflicts, undo.

import { cancelJob, resolveConflict, undoJob } from "../actions.ts"
import { formatBytes, formatDuration } from "../format.ts"
import { t } from "../l10n.ts"
import { canCancel, canUndo, fraction, type Job, secondsLeft } from "../model/jobs.ts"
import { dismissJob, jobList } from "../store.ts"
import { gesture } from "../runtime.ts"

const [applyAll, setApplyAll] = signal(false)

export function jobTitle(j: Job): string {
  const vars = { subject: j.subject, destination: j.destination }
  const doneish = j.phase === "done"
  switch (j.op) {
    case "copy":
      return doneish ? t("job.copied", "Copied {subject} to {destination}", vars) : t("job.copying", "Copying {subject} to {destination}", vars)
    case "move":
      return doneish ? t("job.moved", "Moved {subject} to {destination}", vars) : t("job.moving", "Moving {subject} to {destination}", vars)
    case "trash":
      return doneish ? t("job.trashed", "Moved {subject} to the Trash", vars) : t("job.trashing", "Moving {subject} to the Trash", vars)
    default:
      return doneish ? t("job.deleted", "Deleted {subject}", vars) : t("job.deleting", "Deleting {subject}", vars)
  }
}

export function jobDetail(j: Job, now: number): string {
  switch (j.phase) {
    case "queued":
      return t("job.queued", "Waiting")
    case "preparing":
      return t("job.preparing", "Preparing…")
    case "cancelling":
      return t("job.cancelling", "Stopping…")
    case "cancelled":
      return t("job.cancelled", "Stopped")
    case "failed":
      return j.error?.message ?? t("job.failed", "Failed")
    case "done":
    case "conflict":
      return ""
    default: {
      const parts: string[] = []
      if (j.bytes.total) parts.push(t("job.bytes", "{done} of {total}", { done: formatBytes(j.bytes.done), total: formatBytes(j.bytes.total) }))
      else if (j.items.total) parts.push(t("job.items", "{done} of {total} items", { done: j.items.done, total: j.items.total }))
      const left = secondsLeft(j, now)
      if (left !== null) parts.push(formatDuration(left))
      if (j.crossHost) parts.push(t("job.crossHost", "between hosts"))
      return parts.join(" · ")
    }
  }
}

function conflictRow(j: Job) {
  const c = j.conflict!
  const choose = (choice: "replace" | "skip" | "keep_both") => () => void resolveConflict(j.id, choice, applyAll(), gesture())
  return VStack({ spacing: 6 }, [
    Text(t("conflict.title", "“{name}” already exists in {destination}", { name: c.item, destination: j.destination })).font("callout").weight("semibold").lineLimit(2),
    Text(
      t("conflict.compare", "Existing {existing}, new {incoming}", { existing: formatBytes(c.existing.size), incoming: formatBytes(c.incoming.size) })
    )
      .font("caption")
      .color("secondary"),
    HStack({ spacing: 6 }, [
      Button(t("conflict.replace", "Replace"), choose("replace")).disabled(() => j.pending === "resolve"),
      Button(t("conflict.skip", "Skip"), choose("skip")).disabled(() => j.pending === "resolve"),
      Button(t("conflict.keepBoth", "Keep Both"), choose("keep_both")).disabled(() => j.pending === "resolve"),
      Spacer(),
      Button(HStack({ spacing: 4 }, [Icon(() => (applyAll() ? "checkmark.square" : "square")).size(11), Text(t("conflict.applyAll", "Apply to all")).font("caption")]), () =>
        setApplyAll((v) => !v)
      )
    ])
  ])
}

/** One job; `job` is a keyed signal so progress events update props instead of rebuilding the row. */
export function jobRow(job: CmuxSignal<Job>) {
  // Computed booleans: a progress event changes props, never the row's structure.
  const phase = computed(() => job().phase)
  const active = computed(() => ["running", "preparing", "queued", "conflict"].includes(phase()))
  const undoable = computed(() => canUndo(job()))
  const cancellable = computed(() => canCancel(job()))
  const conflicted = computed(() => (phase() === "conflict" ? job().conflict : null))
  return VStack({ spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Icon(() => (phase() === "failed" ? "exclamationmark.triangle" : phase() === "done" ? "checkmark.circle" : job().op === "trash" ? "trash" : "doc.on.doc"))
        .color(() => (phase() === "failed" ? "danger" : phase() === "done" ? "success" : "secondary"))
        .size(12),
      Text(() => jobTitle(job())).font("callout").lineLimit(1).truncation("middle").frame({ maxWidth: "infinity" }),
      () => (undoable() ? Button(t("job.undo", "Undo"), () => void undoJob(job().undo!, gesture()).then((ok) => ok && dismissJob(job().id))) : null),
      () => (cancellable() ? Button(Icon("xmark.circle.fill").size(12).color("tertiary"), () => void cancelJob(job().id)).help(t("job.cancel", "Stop")) : null),
      () => (active() || phase() === "cancelling" ? null : Button(Icon("xmark").size(10).color("tertiary"), () => dismissJob(job().id)).help(t("job.dismiss", "Dismiss")))
    ]),
    () => (active() ? ProgressView(() => fraction(job())) : null),
    () => (conflicted() ? conflictRow(job()) : null),
    Text(() => jobDetail(job(), Date.now()))
      .font("caption")
      .color(() => (phase() === "failed" ? "danger" : "secondary"))
      .lineLimit(1)
  ]).padding({ top: 8, leading: 10, bottom: 8, trailing: 10 })
}

const VISIBLE_JOBS = 3

/** The jobs strip under the browser; nothing when no job is listed. Guards are computed booleans so a progress event never rebuilds the strip. */
export function jobsStrip() {
  const shown = () => jobList().slice(-VISIBLE_JOBS)
  const any = computed(() => jobList().length > 0)
  const overflow = computed(() => Math.max(0, jobList().length - VISIBLE_JOBS))
  return () =>
    any()
      ? VStack({ spacing: 0 }, [
          Divider(),
          ForEach({ items: shown, key: (j) => j.id }, (j) => jobRow(j)),
          () => (overflow() > 0 ? Text(() => t("job.more", "{n} more operations", { n: overflow() })).font("caption2").color("tertiary").padding(6) : null)
        ])
      : null
}
