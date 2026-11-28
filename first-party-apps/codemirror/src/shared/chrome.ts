// Editor pane chrome: header, banner, status line and the empty/error panel
// (shared by the editor apps; identical copies). Three DEV variants:
//   statusLine - a small status line under the editor (name, notice, position, language)
//   header     - a header above the editor (name, dirty dot, Save) and no status line
//   bare       - the editor only; banners appear only for conflicts and errors

import { t } from "../l10n.ts"
import type { DocState } from "./doc-session.ts"
import { languageName } from "./languages.ts"
import type { Selection } from "./adapter.ts"

export const EDITOR_VARIANTS = ["statusLine", "header", "bare"] as const
export type EditorVariant = (typeof EDITOR_VARIANTS)[number]
export const normalizeVariant = (v: unknown): EditorVariant => ((EDITOR_VARIANTS as readonly unknown[]).includes(v) ? (v as EditorVariant) : "statusLine")

export interface ChromeActions {
  save(): void
  compare(): void
  resolve(keep: "buffer" | "disk"): void
  retry(): void
}

export interface ChromeView {
  name: string
  language: string
  selection: Selection | null
  encoding: string
  lineEnding: string
  library: string
}

function el<K extends keyof HTMLElementTagNameMap>(doc: Document, tag: K, cls: string, text?: string): HTMLElementTagNameMap[K] {
  const e = doc.createElement(tag)
  e.className = cls
  if (text !== undefined) e.textContent = text
  return e
}

function button(doc: Document, label: string, onClick: () => void) {
  const b = el(doc, "button", "cmux-button", label)
  b.type = "button"
  b.addEventListener("click", onClick)
  return b
}

export function readOnlyText(reason: string | undefined): string {
  switch (reason) {
    case "permissions":
      return t("readOnly.permissions", "Read only: no write permission")
    case "provider":
      return t("readOnly.provider", "Read only: the file provider does not allow writes")
    case "largeFile":
      return t("readOnly.largeFile", "Read only: the file is too large to edit")
    case "grant":
      return t("readOnly.grant", "Read only for this app")
    default:
      return t("status.readOnly", "Read only")
  }
}

export function noticeText(s: DocState): string {
  if (s.phase === "saving") return t("status.saving", "Saving")
  switch (s.notice) {
    case "saved":
      return t("status.saved", "Saved")
    case "reloaded":
      return t("status.reloaded", "Reloaded from disk")
    case "merged":
      return t("status.merged", "Merged with an edit from another view")
    case "readOnly":
      return readOnlyText(s.info?.readOnlyReason)
  }
  if (s.readOnly || s.readOnlyProp) return readOnlyText(s.readOnly ? s.info?.readOnlyReason : undefined)
  return s.dirty ? t("status.edited", "Edited") : ""
}

export function positionText(sel: Selection | null): string {
  if (!sel) return ""
  const pos = t("status.position", "Ln {line}, Col {col}", { line: sel.line, col: sel.column })
  return sel.length > 0 ? `${pos} · ${t("status.selection", "{n} selected", { n: sel.length })}` : pos
}

export const displayLanguage = (id: string) => (id === "plaintext" ? t("language.plaintext", "Plain Text") : languageName(id))

/** Builds the chrome around `editorHost` and returns an updater. */
export function createChrome(doc: Document, root: HTMLElement, actions: ChromeActions) {
  root.textContent = ""
  const header = el(doc, "div", "cmux-header")
  const hDot = el(doc, "span", "cmux-dot")
  const hName = el(doc, "span", "cmux-name")
  const hNotice = el(doc, "span", "cmux-notice")
  const hSave = button(doc, t("action.save", "Save"), () => actions.save())
  header.append(hDot, hName, hNotice, el(doc, "span", "cmux-spacer"), hSave)

  const banner = el(doc, "div", "cmux-banner")
  const bText = el(doc, "span", "cmux-text")
  const bButtons = el(doc, "span", "cmux-banner-buttons")
  banner.append(el(doc, "span", "cmux-icon"), bText, bButtons)

  const editorHost = el(doc, "div", "cmux-editor")
  const empty = el(doc, "div", "cmux-empty")
  editorHost.append(empty)

  const status = el(doc, "div", "cmux-status")
  const sDot = el(doc, "span", "cmux-dot")
  const sName = el(doc, "span", "cmux-name")
  const sNotice = el(doc, "span", "cmux-notice")
  const sPos = el(doc, "span", "cmux-pos")
  const sLang = el(doc, "span", "cmux-lang")
  const sEnc = el(doc, "span", "cmux-enc")
  status.append(sDot, sName, sNotice, el(doc, "span", "cmux-spacer"), sPos, sLang, sEnc)
  root.append(header, banner, editorHost, status)

  let bannerKey = ""
  const setBanner = (key: string, kind: "warning" | "error", text: string, buttons: Array<[string, () => void]>) => {
    banner.hidden = !key
    banner.classList.toggle("error", kind === "error")
    if (key === bannerKey) return
    bannerKey = key
    bText.textContent = text
    bButtons.textContent = ""
    for (const [label, fn] of buttons) bButtons.append(button(doc, label, fn))
  }

  return {
    editorHost,
    showEmpty(title: string, message = "") {
      empty.hidden = false
      empty.textContent = ""
      empty.append(el(doc, "strong", "", title))
      if (message) empty.append(el(doc, "span", "", message))
    },
    hideEmpty() {
      empty.hidden = true
    },
    update(variant: EditorVariant, chromeProp: "full" | "none", s: DocState | null, view: ChromeView) {
      const full = chromeProp !== "none"
      header.hidden = !(full && variant === "header")
      status.hidden = !(full && variant === "statusLine")
      const dirty = !!s?.dirty
      const notice = s ? noticeText(s) : ""
      for (const dot of [hDot, sDot]) dot.hidden = !dirty
      hName.textContent = sName.textContent = view.name
      hNotice.textContent = notice === t("status.edited", "Edited") ? "" : notice
      sNotice.textContent = notice
      hSave.disabled = !s || !dirty || s.readOnly || s.readOnlyProp
      sPos.textContent = positionText(view.selection)
      sLang.textContent = displayLanguage(view.language)
      sEnc.textContent = view.encoding ? `${view.encoding.toUpperCase()} · ${view.lineEnding.toUpperCase()}` : ""
      if (s?.phase === "conflict") {
        setBanner("conflict", "warning", t("banner.conflict", "This file changed on disk while you were editing."), [
          [t("action.compare", "Compare"), () => actions.compare()],
          [t("action.keepMine", "Keep Mine"), () => actions.resolve("buffer")],
          [t("action.useDisk", "Use Disk Version"), () => actions.resolve("disk")]
        ])
      } else if (s?.error && s.phase !== "error") {
        setBanner(`error:${s.error.code}`, "error", t("banner.error", "Cannot send the change: {message}", { message: s.error.message }), [[t("action.retry", "Retry"), () => actions.retry()]])
      } else if (variant === "bare" && full && s && (s.readOnly || s.readOnlyProp) && s.info?.readOnlyReason) {
        setBanner("readOnly", "warning", readOnlyText(s.info.readOnlyReason), [])
      } else setBanner("", "warning", "", [])
    }
  }
}

export type Chrome = ReturnType<typeof createChrome>
