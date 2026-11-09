// An inspector pick's data (composer/UIPickChip.tsx): whether a text attachment is one, what its
// report says, and the chip's label parts. The inspector (UIInspectorController.swift pageReport)
// inserts a pick as a text attachment named "UI: <component>" whose text is the full report; the
// prompt sends that report whole (attachments.ts `promptText`), the chip is only how it is drawn.
// Leo, 2026-11-08: "clicking it should be able to show the raw/full thing... idk how possible it'd be
// to also be able to have a well-designed button to click to re-collapse it too."
import { createContext } from "react";
import type { Translate } from "../i18n";
import type { ChipCollapse, ChipLabelPart } from "./contentChipModel";

/// The report's first line (UIInspectorController.swift pageReport).
export const UI_PICK_HEADER = "cmux NEXT app-owned webview selection";
/// The id prefix of a pick's attachment (UIInspectorController.swift deliver).
export const UI_PICK_ID_PREFIX = "ui-pointer-";
/// The name prefix of a pick's attachment ("UI: span").
const NAME_PREFIX = "UI: ";
/// The longest snippet of the picked element's text the label shows, cut at a word's end.
export const UI_PICK_SNIPPET_CHARS = 28;

/// What a report says, as its labelled lines give it; a field the report leaves out, or marks
/// "unavailable", is unset.
export type UIPick = { component?: string; selector?: string; text?: string };

/// Whether a text attachment (or a sent block's name and body) is an inspector pick: its id is the
/// inspector's, or its text is the inspector's report.
export function isUIPick(attachment: { id?: string; text?: string }): boolean {
  if (attachment.id?.startsWith(UI_PICK_ID_PREFIX)) return true;
  return firstLine(attachment.text ?? "") === UI_PICK_HEADER;
}

/// The report's fields. `Text:` may run over several lines, up to the next labelled line.
export function parseUIPick(report: string): UIPick | undefined {
  const lines = report.split(/\r\n|\n|\r/);
  if (lines[0]?.trim() !== UI_PICK_HEADER) return undefined;
  const fields = new Map<string, string>();
  let current: string | undefined;
  for (const line of lines.slice(1)) {
    const match = /^(Component|Source|Selector|Text|Computed styles|DOM): ?(.*)$/.exec(line);
    if (match) {
      current = match[1]!;
      fields.set(current, match[2]!);
    } else if (current) fields.set(current, `${fields.get(current)!}\n${line}`);
  }
  const value = (key: string) => {
    const found = fields.get(key)?.trim();
    return found && found !== "unavailable" ? found : undefined;
  };
  const pick: UIPick = {};
  const component = value("Component");
  const selector = value("Selector");
  const text = value("Text");
  if (component) pick.component = component;
  if (selector) pick.selector = selector;
  if (text) pick.text = text.replace(/\s+/g, " ");
  return pick;
}

/// The element's text cut to `chars` at a word's end, "…" after it when cut; never through a word.
/// A first word longer than `chars` is cut at `chars` (it would otherwise show nothing).
export function pickSnippet(text: string, chars = UI_PICK_SNIPPET_CHARS): string {
  const flat = text.replace(/\s+/g, " ").trim();
  if (flat.length <= chars) return flat;
  const cut = flat.slice(0, chars + 1);
  const space = cut.lastIndexOf(" ");
  const kept = (space > 0 ? cut.slice(0, space) : flat.slice(0, chars)).replace(/[\s.,;:!?·-]+$/, "");
  return `${kept}…`;
}

/// How the chip's label reads a pick (gallery agent-pane.attachment-chip, `label-*`):
/// - `element-snippet` (ships): `span · "the Cloud version-check…"` over `UI element · .cv-li__text`.
///   What the person picked reads first, by the words they saw on it; the kind and selector are the
///   quiet detail.
/// - `prefixed`: the attachment's own name, `UI: span · "the Cloud…"`, over the selector.
/// - `element-selector`: `span · .cv-li__text` over `UI element · "the Cloud…"`.
export type UIPickLabelForm = "element-snippet" | "prefixed" | "element-selector";
export const UI_PICK_LABEL: UIPickLabelForm = "element-snippet";

/// How an opened pick folds back (gallery agent-pane.attachment-chip, `collapse-*`):
/// - `footer` (ships): a bar under the details with a Collapse button at its end, where a paste's
///   opened view keeps its actions; always in view, the details' scroller being bounded.
/// - `corner`: a small Collapse pill in the details' top-right corner.
/// - `chevron`: only a chevron in the face that flips; the face folds it (no button of its own).
export const UI_PICK_COLLAPSE: ChipCollapse = "footer";

/// The forms the composer draws; only the gallery sets others, to compare them.
export const UIPickDesignContext = createContext<{ label: UIPickLabelForm; collapse: ChipCollapse }>({
  label: UI_PICK_LABEL,
  collapse: UI_PICK_COLLAPSE,
});

/// The chip's two rows: its title (what was picked) and its caption (the kind and the rest). Each
/// drops its parts from the end when it has no room. A report that does not parse reads as the
/// attachment's name over the kind.
export function uiPickRows(
  t: Translate,
  name: string,
  report: string,
  form: UIPickLabelForm = UI_PICK_LABEL,
): { title: ChipLabelPart[]; caption: ChipLabelPart[] } {
  const kind: ChipLabelPart = { part: "kind", text: t("composer.uiPick.kind") };
  const pick = parseUIPick(report);
  const element = pick?.component ?? (name.startsWith(NAME_PREFIX) ? name.slice(NAME_PREFIX.length) : undefined);
  if (!pick || !element) return { title: [{ part: "name", text: name }], caption: [kind] };
  const snippet: ChipLabelPart[] = pick.text
    ? [{ part: "snippet", text: t("composer.uiPick.snippet", { text: pickSnippet(pick.text) }) }]
    : [];
  const selector: ChipLabelPart[] =
    pick.selector && pick.selector !== element ? [{ part: "selector", text: pick.selector }] : [];
  if (form === "prefixed")
    return {
      title: [{ part: "name", text: `${NAME_PREFIX}${element}` }, ...snippet],
      caption: [kind, ...selector],
    };
  if (form === "element-selector")
    return { title: [{ part: "name", text: element }, ...selector], caption: [kind, ...snippet] };
  return { title: [{ part: "name", text: element }, ...snippet], caption: [kind, ...selector] };
}

function firstLine(text: string): string {
  const end = text.search(/\r|\n/);
  return (end < 0 ? text : text.slice(0, end)).trim();
}
