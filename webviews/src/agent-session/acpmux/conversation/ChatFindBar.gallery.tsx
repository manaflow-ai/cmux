// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Find in Chat's bar over the real find state (useChatFind) of a short sample transcript: the play
// steps type a query and step through its matches as a reader would.
import { componentEntry } from "../../../gallery/format";
import { assistant, user } from "../../../gallery/fixtures/acpmux";
import { ChatFindBar } from "./ChatFindBar";
import { useChatFind } from "./chatFind";

const rows = [
  user("Why does the retry loop give up after one try?", 6),
  assistant("The retry count is read before the config loads, so it is 1. Move the retry read after load.", 5),
  user("Fix it and add a retry test.", 4),
  assistant("Done: the retry count now comes from the loaded config.", 3),
];

function ChatFindBarGallery() {
  const find = useChatFind(rows);
  // The pane opens the find state with `show` (Cmd-F); here the field's first focus does it.
  return (
    <div
      style={{ position: "relative", height: 64 }}
      onFocusCapture={() => {
        if (!find.open) find.show();
      }}
    >
      <ChatFindBar find={find} />
    </div>
  );
}

const field = { selector: ".acpmux-find__field" };
const countIs = (ctx: { document: Document }, text: string) =>
  ctx.document.querySelector(".acpmux-find__count")?.textContent === text;
// The count's width follows its text and the bar is anchored at its right edge, so the bar grows
// to the left when the count first shows (shipped behavior of ChatFindBar).
const countShift = {
  layoutShiftMax: {
    value: 0.05,
    reason: "The bar is anchored at its right edge and grows to the left when the count text first shows.",
  },
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.chat-find-bar",
  title: "Find in Chat bar",
  area: "Agent pane",
  height: 64,
  covers: ["agent-session/acpmux/conversation/ChatFindBar.tsx#ChatFindBar"],
  load: async () => ChatFindBarGallery,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  widths: { narrow: 360, normal: 640 },
  variants: {
    empty: { note: "The bar as it opens: an empty field, the steps off.", props: {} },
    matches: {
      note: "A query with matches: where the reader is among them.",
      props: {},
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("retry", field);
        await ctx.waitFor(() => countIs(ctx, "1 of 5"));
      },
    },
    "next-match": {
      note: "Return goes to the next match.",
      props: {},
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("retry", field);
        await ctx.waitFor(() => countIs(ctx, "1 of 5"));
        await ctx.press("Enter");
        await ctx.waitFor(() => countIs(ctx, "2 of 5"));
      },
    },
    "no-results": {
      note: "A query with no match.",
      props: {},
      checks: countShift,
      play: async (ctx) => {
        await ctx.type("zzzz", field);
        await ctx.waitFor(
          () =>
            !!ctx.document.querySelector(".acpmux-find__count")?.textContent &&
            ctx.document.querySelector<HTMLButtonElement>(".acpmux-find__step")?.disabled === true,
        );
      },
    },
  },
});
