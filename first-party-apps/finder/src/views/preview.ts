// Preview pane: metadata header plus a built-in text or image placeholder until
// `cmux.viewer/1` embeds exist (finder.md 6, gap G6).

import { formatBytes, formatDate, kindLabel, symbolFor } from "../format.ts"
import { t } from "../l10n.ts"
import type { PreviewState } from "../preview.ts"

function header(s: Exclude<PreviewState, { status: "none" }>) {
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 8 }, [
      Icon(symbolFor(s.entry)).size(22).color(s.group === "folder" ? "accent" : "secondary"),
      VStack({ spacing: 1 }, [Text(s.entry.name).font("headline").lineLimit(2).truncation("middle"), Text(kindLabel(s.group)).font("caption").color("secondary")])
    ]),
    HStack({ spacing: 12 }, [
      s.group === "folder" ? null : meta(t("preview.size", "Size"), formatBytes(s.entry.size)),
      meta(t("preview.modified", "Modified"), formatDate(s.entry.mtime))
    ])
  ]).padding({ top: 10, leading: 12, bottom: 8, trailing: 12 })
}

const meta = (label: string, value: string) =>
  VStack({ spacing: 1 }, [Text(label).font("caption2").color("tertiary"), Text(value).font("caption").color("secondary").lineLimit(1)])

function body(s: Exclude<PreviewState, { status: "none" }>) {
  switch (s.status) {
    case "loading":
      return HStack([ProgressView(), Spacer()]).padding(12)
    case "text":
      return VStack({ spacing: 0 }, [
        VStack({ spacing: 1 }, s.lines.map((line, i) => (s.group === "markdown" ? markdownLine(line, i) : Text(line === "" ? " " : line).font(11).monospaced().lineLimit(1).color("secondary"))))
          .padding(10)
          .frame({ maxWidth: "infinity" })
          .background("hover")
          .cornerRadius(6),
        s.truncated ? Text(t("preview.truncated", "Preview shows the start of the file.")).font("caption2").color("tertiary").padding({ top: 4 }) : null
      ]).padding({ leading: 12, trailing: 12, bottom: 10 })
    case "image":
      return VStack({ spacing: 4, alignment: "center" }, [
        // The scene Image node only loads bundle files: it cannot show an `img_…` thumbnail handle yet (gap G7).
        ZStack([RoundedRectangle({ fill: "hover", cornerRadius: 6 }).frame({ maxWidth: "infinity", height: 150 }), Icon(s.group === "pdf" ? "doc.richtext" : "photo").size(30).color("tertiary")]),
        Text(s.pages ? t("preview.pages", "{w} × {h} · {n} pages", { w: s.width, h: s.height, n: s.pages }) : t("preview.dimensions", "{w} × {h}", { w: s.width, h: s.height }))
          .font("caption")
          .color("secondary")
      ]).padding({ leading: 12, trailing: 12, bottom: 10 })
    case "error":
      return Text(s.error.missing ? t("preview.missing", "Previews need a newer cmux.") : s.error.message).font("caption").color("secondary").padding(12)
    case "meta":
      return s.reason === "folder"
        ? null
        : Text(
            s.reason === "too_large"
              ? t("preview.tooLarge", "Too large to preview.")
              : s.reason === "binary"
                ? t("preview.binary", "No text preview for this file.")
                : t("preview.noViewer", "No viewer app for this kind of file.")
          )
            .font("caption")
            .color("tertiary")
            .padding(12)
  }
}

function markdownLine(line: string, i: number) {
  const h = /^(#{1,3})\s+(.*)$/.exec(line)
  if (h) return Text(h[2]!).font(h[1]!.length === 1 ? "headline" : "subheadline").weight("semibold").lineLimit(1).padding({ top: i === 0 ? 0 : 4 })
  const bullet = /^\s*[-*]\s+(.*)$/.exec(line)
  if (bullet) return Text(`• ${bullet[1]}`).font("caption").lineLimit(1)
  return Text(line === "" ? " " : line.replace(/[*_`]/g, "")).font("caption").color("secondary").lineLimit(1)
}

export function previewPane(state: () => PreviewState) {
  return () => {
    const s = state()
    if (s.status === "none") return EmptyState({ title: t("preview.none", "No selection"), symbol: "eye" })
    return VStack({ spacing: 0 }, [header(s), Divider(), body(s), Spacer()])
  }
}
