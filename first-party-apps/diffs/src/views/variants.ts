// The three designs of the diff pane (DEV/NIGHTLY setting `variant`):
//   split  - file list on the left, the selected file's diff on the right
//   stream - every file in one continuous scroll, each collapsible
//   review - review mode for proposals: summary, per-file decisions, comments, submit

import { t } from "../l10n.ts"
import { counts, verdict } from "../model/review.ts"
import type { FileDiff } from "../model/unified.ts"
import { actionErrorRow, basename, dirname, fileHeader, guarded, stat, statusSymbol, statusTint, toolbar } from "./common.ts"
import { fileControls } from "./decisions.ts"
import { fileBody } from "./filediff.ts"
import type { PaneView } from "./state.ts"

function footer(pv: PaneView) {
  return Text(() => {
    const app = pv.embedApp()
    return app ? t("footer.embed", "Shown with {app}", { app }) : t("footer.builtin", "Built-in diff view")
  })
    .font("caption2")
    .color("tertiary")
    .padding({ top: 6, leading: 10, bottom: 8, trailing: 10 })
}

function fileListRow(pv: PaneView, file: () => FileDiff) {
  return Row({
    title: () => basename(file().path),
    subtitle: () => dirname(file().path) || null,
    symbol: () => statusSymbol(file().status),
    tint: () => statusTint(file().status),
    badge: () => (file().binary ? null : stat(file().additions, file().deletions)),
    selected: () => pv.session.selected() === file().path
  }).onTap(() => pv.session.select(file().path))
}

/** Remounts the body when the selected file or the loaded diff changes. */
function selectedBody(pv: PaneView) {
  return () => {
    const path = pv.session.selected()
    const file = pv.session.files().find((f) => f.path === path)
    if (!file) return EmptyState({ title: t("pane.selectFile", "Select a file"), symbol: "doc.text" })
    return VStack({ spacing: 0 }, [
      fileHeader(pv.session, () => file, { collapsible: false, controls: fileControls(pv, () => file) }),
      fileBody(pv, file)
    ])
  }
}

export function splitView(pv: PaneView) {
  return VStack({ spacing: 0 }, [
    toolbar(pv.session),
    Divider(),
    actionErrorRow(pv.session),
    guarded(pv.session, () =>
      HStack({ spacing: 0 }, [
        VStack({ spacing: 2 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => fileListRow(pv, f)), Spacer()])
          .padding(6)
          .frame({ width: 230, maxHeight: "infinity" }),
        Divider(),
        // HStack has no vertical alignment: both columns fill the pane height and end in a Spacer to stay top-aligned.
        VStack({ spacing: 0 }, [selectedBody(pv), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
      ])
    ),
    footer(pv)
  ])
}

function streamFile(pv: PaneView, file: () => FileDiff) {
  return VStack({ spacing: 0 }, [
    fileHeader(pv.session, file, { collapsible: true, controls: fileControls(pv, file) }),
    () => (pv.session.collapsed(file().path) ? null : fileBody(pv, file()))
  ])
    .borderColor("separator")
    .cornerRadius(6)
}

export function streamView(pv: PaneView) {
  return VStack({ spacing: 0 }, [
    toolbar(pv.session),
    Divider(),
    actionErrorRow(pv.session),
    guarded(pv.session, () => VStack({ spacing: 10 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => streamFile(pv, f))]).padding(10)),
    footer(pv)
  ])
}

function reviewSummary(pv: PaneView) {
  const s = pv.session
  return VStack({ spacing: 6 }, [
    () => {
      const checklist = s.loaded()?.feedItem?.prompt.checklist ?? []
      return checklist.length ? VStack({ spacing: 2 }, checklist.map((c) => HStack({ spacing: 6 }, [Icon("checklist").font("caption").secondary(), Text(c).font("callout")]))) : null
    },
    HStack({ spacing: 8 }, [
      Text(() => {
        const c = counts(s.review(), s.files())
        return t("review.counts", "{accepted} accepted · {rejected} rejected · {pending} left", { accepted: c.accepted, rejected: c.rejected, pending: c.pending })
      })
        .font("caption")
        .secondary(),
      Spacer(),
      Button(t("action.acceptAll", "Accept All"), () => s.decideAll("accept")).font("caption"),
      Button(t("action.rejectAll", "Reject All"), () => s.decideAll("reject")).font("caption"),
      () => {
        if (!s.loaded()?.feedItem) return null
        if (s.submitted()) return Badge(t("review.sent", "Review sent"), "success")
        const v = verdict(s.review(), s.files())
        const label = t(`review.verdict.${v}`, v === "approve" ? "Approve" : v === "request_changes" ? "Request Changes" : "Comment")
        return Button(`${t("action.submit", "Submit Review")}: ${label}`, () => s.submitReview()).font("caption").weight("semibold")
      }
    ])
  ]).padding({ top: 6, leading: 10, bottom: 6, trailing: 10 })
}

export function reviewView(pv: PaneView) {
  return VStack({ spacing: 0 }, [
    toolbar(pv.session),
    reviewSummary(pv),
    Divider(),
    actionErrorRow(pv.session),
    guarded(pv.session, () => VStack({ spacing: 10 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => streamFile(pv, f))]).padding(10)),
    footer(pv)
  ])
}
