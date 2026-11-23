// The composer of a drawn copy (paint.ts) takes clicks and typing before the live composer exists
// (Leo, 2026-11-22: "the point is settled content, and being able to show settled content any time
// you click on something. and to do everything fast. if it means a composer that's TECHNICALLY not
// wholly interactive as in it'd send data but you can click around on it and type in it, that's
// enough. that's the \"functionali-ish skeleton\" we want to aim for").
//
// The copy itself is inert, in a shadow root. Over its prompt this draws one plain editable field
// in the page's light DOM (outside `#root`, so the snapshot writer never sees it), in the copy's
// prompt's own font and padding: a click there puts the caret in it, and the host's readiness
// script (PageInputReadiness) sees an editable take focus, so the keys it queued since the click
// are typed into it at once instead of waiting for the bundle and the editor. It never sends:
// Enter is held (Shift-Enter is a line), and what it holds goes into the live prompt once that
// editor is up (live.ts `handOverSkeleton`). Shared by the boot script and the bundle: it imports
// only shared.ts and the focus route (which imports nothing).
import { focusRoute } from "../../../ui/focusRoute";
import { SNAPSHOT_SKELETON_ATTRIBUTE } from "./shared";

/// The copy's prompt: the editor's editable as the page drew it, else its root (an editor not yet up),
/// else the prompt's box (`copyPrompt`).
const COPY_PROMPT = [
  '.acpmux-composer-prompt [contenteditable="true"]',
  ".acpmux-composer-prompt .acpmux-md-root",
] as const;
/// The copy's placeholder text, hidden once the field holds text.
const COPY_PLACEHOLDER = ".acpmux-composer-prompt .acpmux-md-placeholder";
/// The computed properties the field takes from the copy's prompt, so its text lands where the
/// live editor's will.
const COPIED = [
  "font-family",
  "font-size",
  "font-weight",
  "font-style",
  "line-height",
  "letter-spacing",
  "color",
  "caret-color",
  "padding-top",
  "padding-right",
  "padding-bottom",
  "padding-left",
  "text-align",
  "direction",
  "tab-size",
] as const;

/// The copy's prompt to stand in for, or undefined when there is none to stand in for: no prompt
/// drawn, a hidden one, or one holding a draft (the live editor restores that draft itself, and a
/// field over it would show it twice).
export function copyPrompt(copy: ParentNode): HTMLElement | undefined {
  const box = copy.querySelector(".acpmux-composer-prompt");
  if (!box || box.classList.contains("is-hidden")) return undefined;
  // The first of them with a size: an empty editable can lay out with no height (the copy writes no
  // field's text, so its empty line may be gone), and then the prompt's own box stands in for it.
  let prompt: HTMLElement | undefined;
  const candidates = [...COPY_PROMPT.map((selector) => copy.querySelector<HTMLElement>(selector)), box as HTMLElement];
  for (const candidate of candidates) {
    if (!candidate) continue;
    prompt ??= candidate;
    const rect = candidate.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      prompt = candidate;
      break;
    }
  }
  if (!prompt) return undefined;
  const draft = (box.querySelector(".acpmux-md-root")?.textContent ?? "").trim();
  return draft.length > 0 ? undefined : prompt;
}

/// Draws the field over `prompt` (in the copy, laid out and shown); returns it, or undefined when the
/// prompt has no size. Focuses it when nothing else in the page has focus, as the live composer
/// takes an idle focus when it is up (composerFocus.ts).
export function drawSkeleton(doc: Document, copy: ParentNode, prompt: HTMLElement): HTMLElement | undefined {
  const view = doc.defaultView;
  const rect = prompt.getBoundingClientRect();
  if (!view || !doc.body || rect.width <= 0 || rect.height <= 0) return undefined;
  const style = view.getComputedStyle(prompt);
  const field = doc.createElement("div");
  field.setAttribute(SNAPSHOT_SKELETON_ATTRIBUTE, "");
  // Plain text only: a paste brings no markup, as the live prompt's paste of text does.
  field.contentEditable = "plaintext-only";
  if (field.contentEditable !== "plaintext-only") field.contentEditable = "true";
  field.spellcheck = false;
  // In the tab order, as an editable is anyway (and focusable in engines that ask for it).
  field.tabIndex = 0;
  field.setAttribute("role", "textbox");
  field.setAttribute("aria-multiline", "true");
  const placeholder = copy.querySelector<HTMLElement>(COPY_PLACEHOLDER);
  // The prompt's own label as the page localized it, else its placeholder's words.
  const label = prompt.getAttribute("aria-label") ?? placeholder?.textContent?.trim();
  if (label) field.setAttribute("aria-label", label);
  const copied = COPIED.map((name) => `${name}:${style.getPropertyValue(name)}`).join(";");
  field.style.cssText =
    `${copied};position:fixed;left:${rect.left}px;top:${rect.top}px;width:${rect.width}px;` +
    `min-height:${rect.height}px;max-height:${Math.max(rect.height, view.innerHeight / 3)}px;` +
    "box-sizing:border-box;margin:0;border:0;outline:none;background:transparent;overflow:auto;" +
    "white-space:pre-wrap;overflow-wrap:anywhere;z-index:var(--layer-debug, 2147483000);";
  field.addEventListener("input", () => {
    if (placeholder) placeholder.style.visibility = (field.textContent ?? "").length > 0 ? "hidden" : "";
  });
  // It never sends: Enter is held, a line only with Shift. The live composer sends once it is up.
  field.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) event.preventDefault();
  });
  doc.body.appendChild(field);
  const active = doc.activeElement;
  if (!active || active === doc.body || active === doc.documentElement)
    focusRoute(field, "system", "the chat's copy drew its prompt: an idle focus, as the live composer takes", {
      preventScroll: true,
    });
  return field;
}

/// The field drawn over the copy's prompt, if one shows.
export function skeletonField(doc: Document): HTMLElement | null {
  return doc.querySelector<HTMLElement>(`[${SNAPSHOT_SKELETON_ATTRIBUTE}]`);
}
