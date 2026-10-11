// The review of a planned change: what will be written to which file, before
// anything is written. "full" shows the owner's patch with context, "compact"
// only the changed lines, "summary" only the files and counts (the diff opens
// in the Diffs app).

import { apply, cancel, openInDiffs } from "../actions.ts"
import type { ChangeState, Plan } from "../model/change.ts"
import { parsePatch, type PatchLine } from "../model/patch.ts"
import { t } from "../l10n.ts"
import { change } from "../store.ts"
import { requestChips, sandboxLine } from "./parts.ts"

const MAX_LINES = 40
const LINE_HEIGHT = 16

function line(l: PatchLine) {
  const tone = l.kind === "add" ? "success" : l.kind === "del" ? "danger" : null
  const mark = l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "
  const row = HStack({ spacing: 6 }, [
    Text(String(l.newLine ?? l.oldLine ?? "").padStart(3, " ")).font(10).monospaced().color("tertiary"),
    Text(`${mark} ${l.text.replace(/\t/g, "  ") || " "}`).font(11).monospaced().lineLimit(1).truncation("tail")
  ])
    .padding({ top: 0, leading: 6, bottom: 0, trailing: 6 })
    .frame({ maxWidth: "infinity", height: LINE_HEIGHT })
  return tone ? ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), row]) : row
}

function fileBlock(path: string, kind: string, patch: string, compact: boolean) {
  const files = parsePatch(patch)
  const lines = files.flatMap((f) => f.hunks.flatMap((h) => h.lines)).filter((l) => !compact || l.kind !== "context")
  const adds = files.reduce((n, f) => n + f.additions, 0), dels = files.reduce((n, f) => n + f.deletions, 0)
  const kindText = kind === "create" ? t("file.create", "new file") : kind === "delete" ? t("file.delete", "deleted") : ""
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Icon(kind === "create" ? "doc.badge.plus" : kind === "delete" ? "trash" : "doc.text").font("caption").secondary(),
      Text(path).font("caption").monospaced().lineLimit(1).truncation("head"),
      kindText ? Text(kindText).font("caption").secondary() : null,
      Spacer(),
      Text(`+${adds} −${dels}`).font("caption").monospaced().secondary()
    ]),
    VStack({ spacing: 0 }, lines.slice(0, MAX_LINES).map(line)).background("hover").cornerRadius(4),
    lines.length > MAX_LINES ? Text(t("review.more", "{n} more lines: open in Diffs to see all", { n: lines.length - MAX_LINES })).font("caption").secondary() : null
  ])
}

function summaryBlock(plan: Plan) {
  return VStack(
    { spacing: 2 },
    plan.files.map((f) => {
      const p = parsePatch(f.patch)
      const adds = p.reduce((n, x) => n + x.additions, 0), dels = p.reduce((n, x) => n + x.deletions, 0)
      return HStack({ spacing: 6 }, [Icon("doc.text").font("caption").secondary(), Text(f.path_label).font("caption").monospaced().lineLimit(1).truncation("head"), Spacer(), Text(`+${adds} −${dels}`).font("caption").monospaced().secondary()])
    })
  )
}

function failureText(s: Extract<ChangeState, { phase: "failed" }>): string {
  switch (s.code) {
    case "diff.stale":
      return t("failed.stale", "The files changed again while you reviewed. Look at them and try once more.")
    case "scope.missing":
      return t("failed.scope", "Allow this app to change agent configuration in Settings > Apps.")
    case "operation.unsupported":
      return t("failed.unsupported", "This cmux cannot plan this change yet.")
    case "config.unparseable":
      return t("failed.unparseable", "The agent's config file has comments or errors; cmux does not rewrite it.")
    default:
      return s.message || s.code
  }
}

/** The review card for the current change, or nothing when idle. */
export function reviewCard(mode: "full" | "compact" | "summary") {
  return () => {
    const s = change()
    if (s.phase === "idle") return null
    const header = (title: string, tone: string | null = null) => Text(title).font("headline").color(tone).lineLimit(2)
    let body: unknown
    if (s.phase === "planning") body = HStack({ spacing: 8 }, [ProgressView(null).frame({ width: 12, height: 12 }), Text(t("review.planning", "Preparing the change…")).font("callout").secondary()])
    else if (s.phase === "applied") body = HStack({ spacing: 8 }, [Icon("checkmark.circle.fill").color("success"), Text(t("review.applied", "Applied")).font("callout"), Spacer(), Button(t("action.done", "Done"), () => cancel()).font("caption")])
    else if (s.phase === "failed") body = VStack({ spacing: 6 }, [HStack({ spacing: 6 }, [Icon("exclamationmark.triangle.fill").color("warning"), Text(failureText(s)).font("callout").lineLimit(3)]), HStack({ spacing: 8 }, [Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")])])
    else {
      const plan = s.plan
      const applying = s.phase === "applying"
      body = VStack({ spacing: 8 }, [
        s.phase === "review" && s.note === "stale" ? Text(t("review.stale", "An agent changed these files after the first preview. This is the new diff.")).font("caption").color("warning") : null,
        mode === "summary" ? summaryBlock(plan) : VStack({ spacing: 8 }, plan.files.map((f) => fileBlock(f.path_label, f.kind, f.patch, mode === "compact"))),
        plan.requests?.length ? requestChips(plan.requests) : null,
        plan.sandbox ? sandboxLine(plan.sandbox) : null,
        HStack({ spacing: 10 }, [
          Button(t("action.openInDiffs", "Open in Diffs"), () => void openInDiffs()).font("caption").disabled(applying),
          Spacer(),
          Button(t("action.cancel", "Cancel"), () => cancel()).font("caption").disabled(applying),
          applying ? ProgressView(null).frame({ width: 12, height: 12 }) : Button(t("action.apply", "Apply"), () => void apply()).font("caption").weight("semibold")
        ])
      ])
    }
    return VStack({ spacing: 6 }, [header(s.intent.title), body as CmuxView])
      .padding(10)
      .background("hover")
      .cornerRadius(8)
      .padding({ top: 8, leading: 12, bottom: 4, trailing: 12 })
  }
}
