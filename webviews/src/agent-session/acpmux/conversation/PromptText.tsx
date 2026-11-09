// A sent prompt's text in its bubble (UserBubble.tsx). A prompt taller than twenty lines opens on
// them, the last ones fading out under a mask, with Show more under them and Show less once open,
// as Claude's does (Leo 2026-10-21). A block the composer sent as a paste is part of the message's
// one text body under that one fold (promptCollapse.ts `oneBody`, sentPasteJoin), never a card, a
// chevron or a gap inside the bubble (ask-14d16a6247; Leo, 2026-11-07: "Like just don't separate
// these out."). The choice is kept by the row's id (transcriptDisclosure.tsx), so a prompt scrolled
// out and back, or drawn again from history, stays as the reader left it. Find opens a collapsed
// prompt that holds its current match. The bubble keeps the whole text; Copy copies all of it.
import { type ReactNode, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import { FindReveal, foldFind } from "./chatFind";
import {
  COLLAPSED_PROMPT_LINES,
  HUGE_PROMPT_HEAD_CHARS,
  type PasteRange,
  hasHugeTypedPart,
  isHugePrompt,
  looksLongPrompt,
  headParts,
  promptHead,
  recordedBody,
} from "./promptCollapse";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { foldMotion, foldMs, markHeightFold } from "./fold";
import { type BlockHold, holdBlock } from "./useAnchoredCollapse";
import { Markdown } from "./Markdown";
import { SoftBroken } from "./softBreaks";
import { softBreaks } from "./softBreaksModel";
import { ExpandRow } from "./ExpandRow";
import { isPromptMarkdown } from "./promptMarkdown";
import { UrlChip } from "../chips/LinkChips";
import { githubRefLabel } from "../chips/linkChipsModel";
import { withForeignFiles } from "../chips/linkedText";
import { foreignFileIds, textLinks } from "../chips/paths";
import { deeplinks } from "../composer/deeplinks";
import { SkillWordsContext } from "./skillWords";
import { withSkillWords } from "./withSkillWords";
import { Bot } from "./icons";
import { agentText } from "../agentText";
import { experimentArm } from "../../../experiments/experiment";
import { sentPasteJoin } from "./sentPasteJoin.experiment";
import { SentPromptFoldContext, SentUIPicks } from "./SentUIPick";
import { sentUIPickSegments } from "./sentUIPickModel";

export function PromptText({
  rowId,
  text,
  pasted,
  show,
  children,
  huge: hugeTyped,
  findText,
}: {
  rowId: string;
  /// The prompt as recorded: what Find searches and the paste ranges point into.
  text: string;
  /// What Find searches when it is more than `text` (an inline prompt's text files' bodies), so a
  /// match there opens the fold.
  findText?: string;
  pasted?: readonly PasteRange[];
  /// How a typed part reads in the bubble (a `data:` image as its name, UserBubble.tsx).
  show: (text: string) => string;
  /// Ordered attachments share this fold; opening a pasted block also opens the prompt.
  /// `head`: the prompt is huge and collapsed, so only its first `HUGE_PROMPT_HEAD_CHARS` of text
  /// need drawing (`headParts`).
  /// `collapsed`: the prompt draws folded, so a paste apart from its body needs only its head.
  children?: (open: () => void, head: boolean, collapsed: boolean) => ReactNode;
  /// Whether its text is huge (`hasHugeTypedPart` of its joined body), for `children`.
  huge?: boolean;
}) {
  const t = useT();
  const id = useId();
  const join = experimentArm(sentPasteJoin);
  const parts = useMemo(() => recordedBody(text, pasted ?? [], join), [text, pasted, join]);
  const [open, setOpen] = useTranscriptDisclosure(`prompt:${rowId}`);
  // Whether the prompt is taller than the collapsed lines: guessed from its text until laid out,
  // then measured against its line height (open or closed), again when its width changes. A
  // measure is of one text: a bubble drawn again with another prompt guesses again.
  // A huge part is long too, so it never draws whole before it is measured.
  const guess = looksLongPrompt(text) || parts.length > 3 || hasHugeTypedPart(parts);
  const [measured, setMeasured] = useState<{ parts: typeof parts; long: boolean }>();
  // A huge prompt is always long: collapsed it draws only its head, and a measure of that head
  // (which `show` may shrink to a label) must never unclamp it, or it would flip between head and
  // whole text without end. Its Show more stays; the cost is at most a needless one.
  // Its body, pastes and all; an inline prompt says (`huge`).
  const huge = hugeTyped ?? hasHugeTypedPart(parts);
  const long = huge || (measured?.parts === parts ? measured.long : guess);
  const collapsed = long && !open;
  // What a pick's chip in the body opens with it (SentUIPick.tsx SentUIPickChip).
  const fold = useMemo(() => ({ rowId, collapsed, open: () => setOpen(true) }), [rowId, collapsed, setOpen]);
  // A huge prompt draws literally, and collapsed only its head: the clamp hides the rest anyway,
  // and laying out megabytes of hidden text froze the chat (promptCollapse.ts HUGE_PROMPT_CHARS).
  const head = huge && collapsed;
  const body = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = body.current;
    if (!node) return;
    const measure = () => {
      // The node's own window: a test DOM may install none as a global.
      const style = node.ownerDocument.defaultView?.getComputedStyle?.(node);
      const lineHeight = parseFloat(style?.lineHeight ?? "");
      // Clamped, the text is a box that scrolls; drawn whole it is no box of its own (CSS
      // `display: contents`, so the bubble insets its text as before), and its lines measure it.
      let height = node.scrollHeight;
      if (!node.classList.contains("is-clamped")) {
        height = drawnBox(node)?.height ?? 0;
      }
      // No layout (a test DOM) keeps the guess.
      if (!height || !Number.isFinite(lineHeight)) return;
      const next = height > COLLAPSED_PROMPT_LINES * lineHeight + 1;
      // Folded, a huge typed part or a long paste draws only its head, and a head can read short
      // (a run of zero-width characters, a label) where the whole is long. So a measure of a head
      // only confirms the fold, never lifts it: lifting it would draw the whole, measure long, fold
      // to the head again, and loop until React's update limit. Only the whole text, drawn open or
      // unfolded, can measure short. One rule for typed and pasted parts.
      if (!next && (head || node.querySelector("[data-prompt-head]"))) return;
      // Confirming the guess changes no UI. Keep that mount to one commit; a width or content
      // change that disagrees still updates the fold synchronously before paint.
      setMeasured((last) => ((last?.parts === parts ? last.long : guess) === next ? last : { parts, long: next }));
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    // The bubble: a text drawn whole has no box to observe.
    observer.observe(node.parentElement ?? node);
    return () => observer.disconnect();
  }, [parts, guess, long, open, children, head]);
  const shownParts = useMemo(
    () =>
      head ? headParts(parts, HUGE_PROMPT_HEAD_CHARS, (part) => (part.kind === "text" ? part.text : undefined)) : parts,
    [head, parts],
  );
  // Show more and Show less (Leo 2026-10-21: "these all need animations for expand and collpase"),
  // over the fold's token, without moving what the reader looks at ("just expand the area at the
  // bottom and you're in the same place"):
  // - Show more holds the bubble's top: the text grows below it, and the button rides the bubble's
  //   bottom edge down instead of jumping there.
  // - Show less with the view where Show more left it holds the same top, so the pair puts the view
  //   back where it was however often the reader does it (`holdBlock`; Leo, 2026-11-08: "as you do
  //   that more and more ... there's the drift"). Holding the button here, as since #24050, moved the
  //   view down by what opened on every pair.
  // - Show less after a scroll (under a long prompt scrolled down to) holds the bubble's top while it
  //   is in view, else the button, where the reader clicked it: the text shrinks back above it.
  // At the very bottom a close pins the bottom, as every close there does (VirtualTranscript).
  // A toggle midway starts from the drawn height; unmounting cancels what plays.
  const resized = useRef<number | undefined>(undefined);
  const resizing = useRef<Animation[]>([]);
  const stopResize = () => {
    for (const animation of resizing.current) animation.cancel();
    resizing.current = [];
  };
  useEffect(() => stopResize, []);
  const more = () => body.current?.parentElement?.querySelector<HTMLElement>(":scope > .cv-user__more") ?? null;
  const held = useRef<BlockHold["current"]>(undefined);
  const showMore = (next: boolean) => {
    const bubble = body.current?.parentElement;
    if (bubble) {
      holdBlock(bubble, more(), held, next);
      resized.current = bubble.getBoundingClientRect().height;
    }
    stopResize();
    setOpen(next);
  };
  useLayoutEffect(() => {
    const from = resized.current;
    resized.current = undefined;
    const bubble = body.current?.parentElement;
    const text = body.current;
    // A mount has no previous height to animate. Avoid resolving motion styles until a toggle
    // actually requested a fold; those computed-style reads otherwise flush the cold send layout.
    if (from === undefined || !bubble || !text) return;
    const ms = foldMs(bubble);
    if (ms <= 0) return;
    const to = bubble.getBoundingClientRect().height;
    if (Math.abs(to - from) < 1) return;
    const timing = { duration: ms, easing: foldMotion.easing(bubble) };
    // The rows below are placed before paint while the bubble resizes, as under a fold.
    markHeightFold(bubble, ms);
    if (collapsed) {
      // The clamped text is a box again: it starts as tall as the whole text was drawn.
      const clamped = text.getBoundingClientRect().height;
      resizing.current.push(
        text.animate(
          [
            { height: `${clamped + from - to}px`, maxHeight: "none" },
            { height: `${clamped}px`, maxHeight: "none" },
          ],
          timing,
        ),
      );
      return;
    }
    resizing.current.push(
      bubble.animate(
        [
          { height: `${from}px`, overflow: "hidden" },
          { height: `${to}px`, overflow: "hidden" },
        ],
        timing,
      ),
    );
    const button = more();
    if (button)
      resizing.current.push(button.animate([{ translate: `0 ${from - to}px` }, { translate: "0 0" }], timing));
  }, [collapsed]);
  // Find's current match in this prompt opens it; one in a typed part past the fold, or in a paste,
  // needs it open to draw.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const hit = Boolean(needle && foldFind(findText ?? text).includes(needle));
  useLayoutEffect(() => {
    if (!hit || !collapsed) return;
    setOpen(true);
    reveal?.repaint();
    // A prompt found long only once laid out (a paste, a narrow wrap) opens then; Show less after
    // that stays shut.
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal, long]);
  return (
    <>
      <div ref={body} id={id} className={`cv-user__text${collapsed ? " is-clamped is-faded" : ""}`}>
        <SentPromptFoldContext.Provider value={fold}>
          {children
            ? children(() => setOpen(true), head, collapsed)
            : shownParts.map((part, index) =>
                part.kind === "text" ? (
                  <PromptTyped
                    key={index}
                    text={part.text}
                    show={show}
                    plain={"huge" in part && part.huge === true}
                    slot={`typed:${index}`}
                  />
                ) : (
                  <PastedText key={index} text={part.text} collapsed={collapsed} />
                ),
              )}
        </SentPromptFoldContext.Provider>
      </div>
      {long && (
        <ExpandRow
          className="cv-user__more"
          open={!collapsed}
          controls={id}
          onToggle={() => showMore(collapsed)}
          label={t(collapsed ? "message.more" : "message.less")}
        />
      )}
    </>
  );
}

/// The box `node`'s content is drawn in, for a prompt drawn whole (no box of its own): its text's.
function drawnBox(node: Node): { top: number; bottom: number; height: number } | undefined {
  const range = node.ownerDocument?.createRange();
  if (!range) return undefined;
  range.selectNodeContents(node);
  if (typeof range.getBoundingClientRect !== "function") return undefined;
  const rect = range.getBoundingClientRect();
  return rect.height ? rect : undefined;
}

/// One typed block of a sent prompt: Markdown when it is written in Markdown (promptMarkdown.ts),
/// else its literal text, its line breaks kept (the bubble's `pre-wrap`), a bare web address as a
/// link, and break points in long tokens. A sent prompt's inline parts draw theirs with it too
/// (InlinePromptContent.tsx), so a placed prompt reads as a legacy one does.
export function PromptTyped({
  text,
  show,
  plain,
  slot = "typed:0",
}: {
  text: string;
  show: (text: string) => string;
  /// Which typed part of the prompt it is, keying its picks' disclosures (SentUIPick.tsx).
  slot?: string;
  /// Draw it as one literal text node (a huge prompt's part; promptCollapse.ts HUGE_PROMPT_CHARS).
  plain?: boolean;
}) {
  const shown = show(text);
  // A skill's `/name` draws as the composer's command words do, its description on hover.
  const skills = useContext(SkillWordsContext).words;
  // An inspector pick the composer sent draws as its chip, opening its report in place (SentUIPick.tsx),
  // in a huge prompt too: the chip draws a line, never the report, and the text around it stays
  // literal (`plain` passed on, and a huge part is still huge).
  const picks = sentUIPickSegments(text);
  if (picks)
    return (
      <SentUIPicks
        segments={picks}
        slot={slot}
        typed={(part) => <PromptTyped text={part} show={show} plain={plain} />}
      />
    );
  if (plain || isHugePrompt(text)) return <span className="cv-user__typed">{plainWithForeignFiles(shown)}</span>;
  // Drawn as Markdown, the renderer reads its code as send does (`commonmark`) and lights skills
  // only in its own plain text.
  return isPromptMarkdown(text) ? (
    <Markdown className="cv-user__markdown" thumbnails={false} skills={skills} commonmark>
      {shown}
    </Markdown>
  ) : (
    <span className="cv-user__typed">
      {skills.size && shown.includes("/") ? (
        withSkillWords(shown, skills, (piece, key) => <LiteralText key={key} text={piece} />)
      ) : (
        <LiteralText text={shown} />
      )}
    </span>
  );
}

/// A huge prompt's drawn text (#29840): one literal text node but for provider file ids, each its
/// `ForeignFileRef`. One scan over the drawn text; past `MAX_PLAIN_FOREIGN_IDS` ids it stays one
/// text node, so a prompt of ids alone never draws a node per id.
const MAX_PLAIN_FOREIGN_IDS = 64;

function plainWithForeignFiles(text: string): ReactNode {
  const ids = foreignFileIds(text, MAX_PLAIN_FOREIGN_IDS);
  if (!ids.length || ids.length > MAX_PLAIN_FOREIGN_IDS) return text;
  return withForeignFiles(text, "f", (piece) => [piece], ids);
}

/// Literal prompt text with each bare web address a link (UrlChip, as in a reply) and each cmux app
/// link (`cmux://workspace/…`, `cmux-nightly://agent/…`) a link the host opens in the app, as a
/// reply's app link draws (Markdown.tsx); the rest keeps its break points (softBreaks.tsx).
function LiteralText({ text }: { text: string }) {
  const links = text.includes("://") ? promptLinks(text) : [];
  if (!links.length) return <>{withForeignFiles(text, "f", softBreaks)}</>;
  const out: ReactNode[] = [];
  let at = 0;
  links.forEach((link, index) => {
    if (link.start > at) out.push(...withForeignFiles(text.slice(at, link.start), `t${index}`, softBreaks));
    out.push(
      link.app ? (
        // A plain anchor, so the click takes the host's link path (opened in the app).
        <a key={`a${index}`} className="cv-link is-app" href={link.value}>
          <SoftBroken text={link.value} />
        </a>
      ) : (
        <UrlChip key={`u${index}`} href={link.value}>
          {githubRefLabel(link.value) ?? link.value}
        </UrlChip>
      ),
    );
    at = link.end;
  });
  if (at < text.length) out.push(...withForeignFiles(text.slice(at), "tail", softBreaks));
  return <>{out}</>;
}

/// The links of a literal prompt, in order: its web addresses and its cmux app links.
function promptLinks(text: string): { start: number; end: number; value: string; app: boolean }[] {
  const web = textLinks(text)
    .filter((link) => link.kind === "url")
    .map((link) => ({ start: link.start, end: link.end, value: link.value, app: false }));
  const app = deeplinks(text)
    .filter((link) => !link.href.startsWith("https:"))
    .map((link) => ({ start: link.start, end: link.end, value: link.href, app: true }));
  if (!app.length) return web;
  const free = web.filter((link) => !app.some((other) => link.start < other.end && other.start < link.end));
  return [...free, ...app].sort((a, b) => a.start - b.start);
}

/// A paste another agent wrote, apart from the message's body (promptCollapse.ts `agentPaste`): its characters on
/// their own lines, literal, under the prompt's one fold, with a quiet "Pasted from <agent>" line over
/// it so it never passes as the person's words (ask-fa4c523fa8). No card, no label to open and no
/// fold of its own (ask-14d16a6247). A text file's body, its chip opened (InlinePromptContent.tsx
/// PromptTextFile), draws the same, with no line over it (`file`).
/// Folded, a long one draws only its head, far more than the fold shows (HUGE_PROMPT_HEAD_CHARS), so
/// a megabyte lays out no more than a short one. model.ts estimates the same.
export function PastedText({ text, collapsed, file }: { text: string; collapsed: boolean; file?: boolean }) {
  const t = useT();
  const from = useMemo(() => {
    if (file) return undefined;
    const found = agentText(text);
    if (!found.signals.length) return undefined;
    return found.from ? t("transcript.pastedFrom", { name: found.from }) : t("transcript.pastedFromAgent");
  }, [text, t, file]);
  const shown = collapsed ? promptHead(text, HUGE_PROMPT_HEAD_CHARS) : text;
  return (
    // A cut head: the fold's measure of it may only confirm the fold (PromptText).
    <span className="cv-user__pasted" dir="auto" data-prompt-head={shown === text ? undefined : ""}>
      {from && (
        <span className="cv-user__pasted-from" data-find-skip="">
          <Bot size={12} />
          {from}
        </span>
      )}
      {shown}
    </span>
  );
}
