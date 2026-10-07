// One file's diff body. With an editor app installed (and the proposed `Embed`
// scene node), the user's `cmux.editor/1` renders it; otherwise the built-in
// scene diff below does (inline or side by side), which also proves the scene
// API can carry a real diff.

import { EDITOR_INTERFACE, type EditorProps } from "../interfaces/editor.ts"
import type { EmbedCreateResult } from "../interfaces/embed.ts"
import { t } from "../l10n.ts"
import { commentsAt, sideBySide, type SideRow } from "../model/review.ts"
import type { DiffLine, FileDiff, Hunk } from "../model/unified.ts"
import { editorApp, fallbackLines, layout } from "../settings.ts"
import { hunkControls } from "./decisions.ts"
import type { PaneView } from "./state.ts"

const pad = (n: number | null, w = 4) => (n === null ? "" : String(n)).padStart(w, " ")
const shown = (text: string) => text.replace(/\t/g, "    ") || " "
const toneOf = (l: DiffLine | null) => (l?.kind === "add" ? "success" : l?.kind === "del" ? "danger" : null)

/** The proposed scene node that places another app's mount (README, gaps). */
type EmbedBuilder = (props: { embed: string; minHeight?: number }) => CmuxView
const embedBuilder = (): EmbedBuilder | null => {
  const e = (globalThis as { Embed?: unknown }).Embed
  return typeof e === "function" ? (e as EmbedBuilder) : null
}
export const canEmbed = () => embedBuilder() !== null

/** Fixed line height: a flexible tint band would otherwise take spare vertical space. */
const LINE_HEIGHT = 17

/** A changed line or cell: a tinted band behind the content. */
function tinted(tone: string | null, content: CmuxView) {
  if (!tone) return content
  return ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), content])
}

function lineRow(pv: PaneView, path: string, l: DiffLine) {
  const side = l.newLine === null ? "old" : "new"
  const line = (l.newLine ?? l.oldLine)!
  const marker = l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "
  const row = HStack({ spacing: 6 }, [
    Text(`${pad(l.oldLine)} ${pad(l.newLine)}`).font(11).monospaced().color("tertiary"),
    Text(`${marker} ${shown(l.text)}`).font(12).monospaced().lineLimit(1).truncation("tail")
  ])
    .padding({ top: 0, leading: 6, bottom: 0, trailing: 6 })
    .frame({ maxWidth: "infinity", height: LINE_HEIGHT })
    .background(() => (pv.isTarget(path, line, side) ? "selected" : null))
    .onTap(() => pv.setTarget({ path, line, side }))
  return tinted(toneOf(l), row)
}

function cell(pv: PaneView, path: string, l: DiffLine | null, side: "old" | "new") {
  if (!l) return Text(" ").font(12).monospaced().frame({ maxWidth: "infinity", height: LINE_HEIGHT }).background("hover")
  const no = side === "old" ? l.oldLine : l.newLine
  const content = HStack({ spacing: 6 }, [Text(pad(no)).font(11).monospaced().color("tertiary"), Text(shown(l.text)).font(12).monospaced().lineLimit(1).truncation("tail")])
    .padding({ top: 0, leading: 4, bottom: 0, trailing: 4 })
    .frame({ maxWidth: "infinity", height: LINE_HEIGHT })
    .background(() => (no !== null && pv.isTarget(path, no, side) ? "selected" : null))
    .onTap(() => (no !== null ? pv.setTarget({ path, line: no, side }) : undefined))
  return tinted(l.kind === "context" ? null : toneOf(l), content)
}

function sideRow(pv: PaneView, path: string, row: SideRow) {
  // A Divider is height-flexible and would stretch the row; a fixed 1 pt rule keeps rows at LINE_HEIGHT.
  return HStack({ spacing: 0 }, [cell(pv, path, row.left, "old"), Rectangle().fill("separator").frame({ width: 1, height: LINE_HEIGHT }), cell(pv, path, row.right, "new")])
}

function hunkHeader(pv: PaneView, file: FileDiff, h: Hunk) {
  return HStack({ spacing: 6 }, [
    Text(`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@ ${h.section}`.trim()).font(11).monospaced().secondary().lineLimit(1).truncation("tail"),
    Spacer(),
    hunkControls(pv, file, h)
  ]).padding({ top: 3, leading: 8, bottom: 3, trailing: 8 })
}

/** Comments on lines of this hunk, then the comment field when the target line is in it. */
function hunkComments(pv: PaneView, file: FileDiff, h: Hunk) {
  return () => {
    const state = pv.session.review()
    const notes = h.lines.flatMap((l) => commentsAt(state, file.path, l))
    const target = pv.target()
    const here = target && target.path === file.path && h.lines.some((l) => (target.side === "new" ? l.newLine === target.line : l.newLine === null && l.oldLine === target.line))
    if (!notes.length && !here) return null
    return VStack({ spacing: 4 }, [
      ...notes.map((c) =>
        HStack({ spacing: 6 }, [
          Icon("text.bubble").font("caption").secondary(),
          Text(`${c.side === "old" ? "−" : ""}${c.line}  ${c.body}`).font("callout").lineLimit(4),
          Spacer(),
          Button(Icon("xmark"), () => pv.session.removeComment(c.id)).help(t("action.deleteComment", "Delete Comment"))
        ])
      ),
      here
        ? TextField("", {
            placeholder: t("comment.placeholder", "Add a comment"),
            autofocus: true,
            onSubmit: (text) => {
              pv.setTarget(null)
              return pv.session.comment(target!.path, target!.line, target!.side, text)
            },
            onCancel: () => pv.setTarget(null)
          })
            .font("callout")
            .padding({ top: 4, leading: 8, bottom: 4, trailing: 8 })
            .background("hover")
            .cornerRadius(6)
        : null
    ]).padding({ top: 4, leading: 12, bottom: 6, trailing: 10 })
  }
}

/** Hunks until the per-file line budget (the scene allows 4096 nodes per mount). */
function budgeted(pv: PaneView, file: FileDiff): { hunks: Hunk[]; hidden: number } {
  const budget = fallbackLines() + (pv.session.shownLines(file.path) ?? 0)
  const out: Hunk[] = []
  let used = 0
  for (const h of file.hunks) {
    if (used > 0 && used + h.lines.length > budget) break
    out.push(h)
    used += h.lines.length
  }
  const total = file.hunks.reduce((s, h) => s + h.lines.length, 0)
  return { hunks: out, hidden: total - used }
}

export function sceneDiff(pv: PaneView, file: FileDiff) {
  if (file.binary) return Text(t("file.binary", "Binary file")).font("callout").secondary().padding(10)
  return Group([
    () => {
    const side = layout() === "sideBySide"
    const { hunks, hidden } = budgeted(pv, file)
    return VStack({ spacing: 0 }, [
      ...hunks.flatMap((h) => [
        hunkHeader(pv, file, h),
        VStack({ spacing: 0 }, side ? sideBySide(h).map((r) => sideRow(pv, file.path, r)) : h.lines.map((l) => lineRow(pv, file.path, l))),
        hunkComments(pv, file, h)
      ]),
      hidden > 0
        ? Button(t("action.showMore", "Show {n} more lines", { n: hidden }), () => pv.session.showMore(file.path, fallbackLines())).font("caption").padding(8)
        : null
    ])
    }
  ])
}

/** Editor props for one file of a diff resource (`cmux.editor/1` diff mode). */
export function editorDiffProps(diff: string, file: FileDiff, mode: "sideBySide" | "inline"): EditorProps {
  return {
    readOnly: true,
    chrome: "none",
    diff: {
      original: { diff, path: file.oldPath ?? file.path, side: "base" },
      modified: { diff, path: file.path, side: "head" },
      layout: mode,
      path: file.path
    }
  }
}

/** The user's editor app through `ui.embed.create`; the scene diff when it is missing or fails. */
export function fileBody(pv: PaneView, file: FileDiff) {
  const build = embedBuilder()
  const diff = pv.session.loaded()?.resource.diff
  if (!build || !diff || file.binary) return sceneDiff(pv, file)
  const [embed, setEmbed] = signal<EmbedCreateResult | null>(null)
  const [failed, setFailed] = signal(false)
  cmux
    .call<EmbedCreateResult>("ui.embed.create", { interface: EDITOR_INTERFACE, props: editorDiffProps(diff, file, layout()), prefer: editorApp(), minHeight: 120 })
    .then((r) => {
      setEmbed(r)
      pv.noteEmbed(r)
    })
    .catch(() => setFailed(true))
  let sentMode = layout()
  effect(() => {
    const mode = layout()
    const e = embed()
    if (!e || mode === sentMode) return
    sentMode = mode
    cmux.call("ui.embed.update", { embed: e.embed, props: editorDiffProps(diff, file, mode) }).catch(() => setFailed(true))
  })
  return Group([
    () => {
      if (failed()) return sceneDiff(pv, file)
      const e = embed()
      return e ? build({ embed: e.embed, minHeight: 120 }) : ProgressView()
    }
  ])
}
