// l10n-allow-file: gallery fixtures (sample drafts, a workspace title and its link), not shipped UI.
// A pasted workspace link in the composer is a chip the caret moves around as one character, and a
// later paste never turns it back into its URL (Leo, 2026-11-09: "when I do these links that I copy,
// the caret sort of disappears on it, and then after I paste in another thing, it just becomes
// unformatted again"); the composer takes typing while a Cloud chat starts (Leo: "I can't click
// into the composer at all to, like potentially type other stuff while it's doing that initial
// load situation"). Each variant is the real Composer with the app's link places set.
import { componentEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { ComposerHandle } from "./Composer";
import type { MarkdownFieldElement } from "./MarkdownField";

const HEX = "a21d11e10694e6e0fbf7ea446075f32c";
const WORKSPACE = `cmux-nightly://workspace/ws_${HEX}`;

type Props = { draft: string; locked?: boolean };

/** The field's handle, once the draft drew its chips. */
const field = async (ctx: PlayContext, chips: number) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-md .is-titled[data-title]").length === chips);
  const element = ctx.document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!;
  const md = element.acpmuxMarkdownField!;
  md.focus();
  return md;
};

/** The caret `offset` characters into the draft, after its chips drew. */
const caretAt = (offset: (draft: string) => number, chips = 1) => async (ctx: PlayContext) => {
  const md = await field(ctx, chips);
  md.setCaret(offset(md.plainText()));
};

/** `text` pasted at the draft's end, then the caret's place checked. */
const pasteAtEnd = (text: string, chips: number) => async (ctx: PlayContext) => {
  const md = await field(ctx, 1);
  md.setCaret(md.plainText().length);
  md.pasteText(text);
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-md .is-titled[data-title]").length === chips);
};

/** Typed while the Cloud start is out: the composer takes it. */
const typeWhileStarting = async (ctx: PlayContext) => {
  const element = ctx.document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!;
  await ctx.waitFor(() => Boolean(element.acpmuxMarkdownField));
  await ctx.click({ selector: ".acpmux-md" });
  element.acpmuxMarkdownField!.insertTyped("and also check the sidebar tests");
  await ctx.waitFor(() => element.acpmuxMarkdownField!.plainText().includes("sidebar tests"));
};

export default componentEntry<Props>({
  id: "agent-pane.composer-chip-caret",
  title: "Composer link chip caret",
  area: "Agent pane",
  pane: true,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  height: 260,
  covers: [
    "agent-session/acpmux/composer/deeplinkTitles.ts",
    "agent-session/acpmux/composer/deeplinks.ts",
    "agent-session/acpmux/markdownField.css",
    "agent-session/acpmux/Composer.tsx",
  ],
  keywords: ["deeplink", "workspace link", "chip", "caret", "paste", "cloud", "starting"],
  styles: async () => {
    await import("./styles.css");
    await import("./markdownField.css");
    await import("./composerLook.css");
  },
  load: async () => {
    const { useEffect, useRef } = await import("react");
    const { Composer } = await import("./Composer");
    const { setLinkPlaces } = await import("./chips/cmuxLinkPlaces");
    setLinkPlaces([{ id: `ws_${HEX}`, kind: "workspace", title: "workspace-413" }]);
    const sessionId = "gallery-chip-caret";
    const snapshot = noChat([], {
      sessionId,
      summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
    });
    const Chips = () => null;
    return function ChipCaret({ draft, locked }: Props) {
      const handle = useRef<ComposerHandle>(null);
      useEffect(() => {
        if (draft) handle.current?.restore(draft, []);
      }, [draft]);
      return (
        <Composer
          handle={handle}
          snapshot={snapshot}
          sessionId={sessionId}
          chips={Chips}
          onStop={() => {}}
          onSend={() => true}
          locked={locked === true}
        />
      );
    };
  },
  variants: {
    "caret-after-chip": {
      note: "The link pasted alone: the chip with the caret after it, at the line's height (it had been drawn at no height inside the chip).",
      props: { draft: WORKSPACE },
      play: caretAt((draft) => draft.length),
    },
    "caret-before-chip": {
      note: "The caret before the chip, in front of its icon.",
      props: { draft: `See ${WORKSPACE}` },
      play: caretAt(() => "See ".length),
    },
    "chip-mid-text": {
      note: "The chip mid-sentence, the caret at the end of the text after it.",
      props: { draft: `Open ${WORKSPACE} and compare it with the last run` },
      play: caretAt((draft) => draft.length),
    },
    "after-second-paste": {
      note: "The same link pasted again right after the chip: both stay chips, a space between (the first had turned back into its URL).",
      props: { draft: WORKSPACE },
      play: pasteAtEnd(WORKSPACE, 2),
    },
    "after-pasted-text": {
      note: "Text pasted right after the chip: the chip stays, a space before the text.",
      props: { draft: WORKSPACE },
      play: pasteAtEnd("can you look at this one", 1),
    },
    "starting-chat": {
      note: "A Cloud start is out (locked): the composer still takes a click and typing; Send keeps the draft until the start ends.",
      props: { draft: "", locked: true },
      play: typeWhileStarting,
    },
  },
});
