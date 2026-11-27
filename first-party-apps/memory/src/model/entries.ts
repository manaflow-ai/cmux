// Markdown memory as entries: one entry per list item (with its continuation
// lines) or per paragraph, under the nearest heading. Line numbers are
// 1-based; `end` is exclusive.

export type Entry = { start: number; end: number; text: string; section: string | null; bullet: boolean }

const BULLET = /^\s*(?:[-*+]|\d+[.)])\s+/
const HEADING = /^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/
const FENCE = /^\s*(```|~~~)/

export function parseEntries(text: string): Entry[] {
  const lines = text.replace(/\n$/, "").split("\n")
  const out: Entry[] = []
  let section: string | null = null
  let cur: Entry | null = null
  let inFence = false
  let frontMatter = lines[0]?.trim() === "---"
  const close = (i: number) => {
    if (cur) {
      cur.end = i + 1
      out.push(cur)
      cur = null
    }
  }
  lines.forEach((line, idx) => {
    const n = idx + 1
    if (frontMatter) {
      if (idx > 0 && line.trim() === "---") frontMatter = false
      return
    }
    if (FENCE.test(line)) {
      inFence = !inFence
      if (!cur) cur = { start: n, end: n + 1, text: line, section, bullet: false }
      else cur.text += `\n${line}`
      return
    }
    if (inFence) {
      if (cur) cur.text += `\n${line}`
      return
    }
    const h = HEADING.exec(line)
    if (h) {
      close(n - 1)
      section = h[1]!
      return
    }
    if (line.trim() === "") {
      close(n - 1)
      return
    }
    if (BULLET.test(line)) {
      close(n - 1)
      cur = { start: n, end: n + 1, text: line.replace(BULLET, ""), section, bullet: true }
      return
    }
    if (cur) {
      cur.text += `\n${line.trim()}`
      cur.end = n + 1
    } else cur = { start: n, end: n + 1, text: line.trim(), section, bullet: false }
  })
  close(lines.length)
  return out
}

/** The first line of an entry, for one-line rows. */
export const firstLine = (e: Entry) => e.text.split("\n")[0]!
