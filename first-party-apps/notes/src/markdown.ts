// Markdown-lite line classification. The renderer has no Markdown node yet
// (README, "Proposed scene nodes"), so the app styles each body line itself.

export type LineKind = "heading" | "bullet" | "check" | "number" | "quote" | "code" | "fence" | "rule" | "blank" | "text"

export interface Line {
  index: number
  kind: LineKind
  /** Text to show, with the markdown marker removed (code lines keep their text as is). */
  text: string
  /** Heading level 1-6, or list indent depth. */
  level: number
  checked: boolean
  /** "1." for numbered items. */
  marker: string
}

const leadingDepth = (s: string) => Math.min(4, Math.floor((s.match(/^\s*/)?.[0].replace(/\t/g, "  ").length ?? 0) / 2))

export function parseLines(body: string): Line[] {
  if (!body) return []
  const out: Line[] = []
  let inFence = false
  body.split("\n").forEach((raw, index) => {
    const base = { index, level: 0, checked: false, marker: "" }
    if (/^\s*(```|~~~)/.test(raw)) {
      inFence = !inFence
      out.push({ ...base, kind: "fence", text: raw.trim().replace(/^(```|~~~)/, "") })
      return
    }
    if (inFence) return void out.push({ ...base, kind: "code", text: raw })
    if (!raw.trim()) return void out.push({ ...base, kind: "blank", text: "" })
    let m: RegExpMatchArray | null
    if ((m = raw.match(/^\s{0,3}(#{1,6})\s+(.*)$/))) return void out.push({ ...base, kind: "heading", level: m[1]!.length, text: m[2]!.trim() })
    if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(raw)) return void out.push({ ...base, kind: "rule", text: "" })
    if ((m = raw.match(/^(\s*)[-*+]\s+\[([ xX])\]\s?(.*)$/))) return void out.push({ ...base, kind: "check", level: leadingDepth(m[1]!), checked: m[2] !== " ", text: m[3]! })
    if ((m = raw.match(/^(\s*)[-*+]\s+(.*)$/))) return void out.push({ ...base, kind: "bullet", level: leadingDepth(m[1]!), text: m[2]! })
    if ((m = raw.match(/^(\s*)(\d+[.)])\s+(.*)$/))) return void out.push({ ...base, kind: "number", level: leadingDepth(m[1]!), marker: m[2]!, text: m[3]! })
    if ((m = raw.match(/^\s*>\s?(.*)$/))) return void out.push({ ...base, kind: "quote", text: m[1]! })
    out.push({ ...base, kind: "text", text: raw })
  })
  return out
}

/** Inline markdown shown as plain text (the renderer has no attributed text): links keep their label. */
export const inlineText = (s: string) =>
  s
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "[$1]")
    .replace(/\[([^\]]+)\]\(([^)]*)\)/g, "$1")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/(^|[^*\w])[*_]([^*_\s][^*_]*?)[*_](?=[^*\w]|$)/g, "$1$2")
    .replace(/`([^`]+)`/g, "$1")
