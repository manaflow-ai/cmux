import type { EditorState } from "@milkdown/kit/prose/state";
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import type { CmuxLinkInfo } from "../chips/cmuxLinkResolve";
import { deeplinksKey } from "./deeplinkTokens";

// A cmux link in the draft drawn as what it names, as the sent message draws it
// (chips/CmuxLinkChip.tsx; Leo, 2026-11-08: "when I paste the URL link, when I do the right-click
// copy link to workspace thing, it should be able to render in the box that it is an actual chat
// that is there, like with the title and whatever"). Only a decoration: the draft's text stays the
// link, so send, copy, paste and undo see exactly what was pasted. The link's own characters are
// drawn at no width under the chip (markdownField.css `.is-titled`: the kind's icon on its ::before,
// the title on its ::after with the sent chip's wash), and come back as text while
// the caret is inside the link, so it can still be edited; the caret at either end keeps the chip.
// The links come from deeplinkTokens.ts's decorations, so nothing reads the draft again here.

/// The class a titled link draws with (markdownField.css).
export const TITLED_CLASS = "is-titled";

export type DeeplinkTitles = {
  /// What a link names now, from the page's stores; undefined keeps it a link.
  known(href: string): CmuxLinkInfo | undefined;
  /// Hears a change of anything `known` reads; returns its stop.
  subscribe(listener: () => void): () => void;
  /// The chip's label for `info` (its title, and another machine's name).
  label(info: CmuxLinkInfo): string;
  /// The CSS mask image of `info`'s kind icon (icons/iconMask.ts), or undefined for none.
  icon?(info: CmuxLinkInfo): string | undefined;
};

const key = new PluginKey<number>("acpmuxDeeplinkTitles");

/// Draws each known link in the draft as its chip. `titles` undefined draws nothing.
export function deeplinkTitlesPlugin(titles: DeeplinkTitles | undefined): Plugin {
  let cached: { links: DecorationSet; head: number; anchor: number; version: number; set: DecorationSet } | undefined;
  const decorate = (state: EditorState): DecorationSet => {
    const links = deeplinksKey.getState(state);
    if (!titles || !links) return DecorationSet.empty;
    const version = key.getState(state) ?? 0;
    const { head, anchor } = state.selection;
    if (
      cached &&
      cached.links === links &&
      cached.head === head &&
      cached.anchor === anchor &&
      cached.version === version
    )
      return cached.set;
    const found = links.find(undefined, undefined, (spec) => typeof spec.deeplink === "string");
    const decorations: Decoration[] = [];
    for (const link of found) {
      // The caret or a selection inside the link: its text, to edit.
      const inside = (head > link.from && head < link.to) || (anchor > link.from && anchor < link.to);
      if (inside) continue;
      const info = titles.known(link.spec.deeplink as string);
      if (!info) continue;
      const icon = titles.icon?.(info);
      decorations.push(
        Decoration.inline(link.from, link.to, {
          class: TITLED_CLASS,
          "data-title": titles.label(info),
          "data-kind": info.kind,
          // The kind's icon on the chip's ::before (markdownField.css), as the sent chip draws it.
          ...(icon && { "data-icon": "", style: `--cmux-link-icon: ${icon}` }),
        }),
      );
    }
    const set = decorations.length ? DecorationSet.create(state.doc, decorations) : DecorationSet.empty;
    cached = { links, head, anchor, version, set };
    return set;
  };
  return new Plugin({
    key,
    state: {
      init: () => 0,
      apply: (tr, value) => (tr.getMeta(key) ? value + 1 : value),
    },
    view: (view) => {
      // A rename, a new chat or a closed workspace redraws the chips (one transaction per change).
      const stop = titles?.subscribe(() => {
        if (!view.isDestroyed) view.dispatch(view.state.tr.setMeta(key, true).setMeta("addToHistory", false));
      });
      return { destroy: () => stop?.() };
    },
    props: { decorations: decorate },
  });
}
