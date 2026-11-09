import { Fragment, type ReactNode } from "react";
import { useT } from "../i18n";
import { appHref, safeHref } from "../model";
import { needsYouListOff, needsYouTarget, openNeedsYou } from "../needsYou/links";
import { ImageIcon } from "./icons";
import { MathInline } from "./Math";
import { codeSpans } from "../slashCommands";
import { ForeignFileRef, PathChip, SiblingFileChip, UrlChip } from "../chips/LinkChips";
import { isBareFileName, ReplyFoldersContext } from "../chips/replyFolders";
import { SoftBroken } from "./softBreaks";
import { codePath, foreignFileId, isTemplatePath, linkPath, pathName } from "../chips/paths";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { StartedSessionChip } from "../started/StartedSessionCard";
import { CmuxLinkChip } from "../chips/CmuxLinkChip";
import { cmuxLinkTarget } from "./cmuxLinks";
import { type StartedMentions } from "../started/startedSessionCardModel";
import { isAgentMotionOff } from "../../shared/motion";
import { animateScroll } from "../threadMinimap/scrollMotion";
import { SessionRefCode } from "./SessionRef";
import { agentRef } from "./sessionRefs";
import { JUMP_CURVE, jumpDuration } from "../threadMinimap/model";
import {
  INLINE_IMAGE,
  MAX_DATA_URL_LENGTH,
  OVERSIZED_DATA_URL,
  DATA_REF,
  capDataUrls,
  linkKind,
  linkIcon,
  INLINE_RE,
} from "./markdownModel";
import { proseText } from "./proseText";

/* ---------------- Inline ---------------- */

export type InlineOptions = {
  /** Icon drawn before a link's text; default `linkIcon` below. */
  linkIcon?: (href: string) => ReactNode | null;
  /** The reply's footnotes: each id's number and the element id of its note. */
  notes?: FootnoteNumbers;
  /** Long data URLs of this text, by the index their short stand-in names (`capDataUrls`). */
  dataRefs?: string[];
  /** Data URLs past the reply's total budget (MAX_REPLY_DATA_URLS): drawn as their name. */
  overBudget?: Set<string>;
  /** The workspace's GitHub `owner/repo`, used for bare issue references. */
  githubRepository?: string;
  /** Link GitHub references in prose; labels of an outer link disable this. */
  linkGithubReferences?: boolean;
  /** Link a bare `#N` too (default). Off in a quote: quoted words are someone else's, whose `#1`
   *  is rarely this repository's pull request (Leo 2026-10-29: "these auto render to the pr
   *  instead of just #1 #2..."). `owner/repo#N` and addresses still link there. */
  linkBareReferences?: boolean;
  /** The chats the open chat started, whose names draw as chips (started/startedSessions.ts). */
  started?: StartedMentions;
  /** A sent prompt's skills by shown name, with their descriptions: each `/name` in the renderer's
   *  plain text draws as a skill word (SkillWord.tsx), never in code. */
  skills?: ReadonlyMap<string, string>;
  /** Inline code read as CommonMark reads it (slashCommands.ts codeSpans: a span closes on a run of
   *  as many backticks, so ``a ` b`` is one span), as a sent prompt's is. */
  commonmark?: boolean;
  /** The code spans `renderInline` set aside in this text (`commonmark`), by the index their stand-in
   *  names; set by the outermost call, read by the calls inside it. */
  codes?: string[];
  /** How a commit SHA draws: a GitHub chip (replies), or quiet monospace text that links to its
   *  commit when its repository is known (another agent's message, IncomingMessageCard.tsx). */
  commits?: "chip" | "quiet";
  /** An image path draws as a thumbnail too (default): under its sentence, or in its place in a
   *  paragraph of images. Off, only its chip: another machine's files in another agent's message
   *  (IncomingMessageCard.tsx). Markdown image syntax (`![shot](/a.png)`) still draws in place. */
  thumbnails?: boolean;
};

export type FootnoteNumbers = { numbers: Map<string, number>; anchor: (id: string) => string };

/// `src/app.ts:12` keeps its line in the chip's label (the chip opens the file).
function lineLabel(path: string, written: string): string | undefined {
  const line = /:(\d+)(?::\d+)?$/.exec(written)?.[1];
  return line ? `${pathName(path)}:${line}` : undefined;
}

/// Each code span of `source` (CommonMark, slashCommands.ts codeSpans) set aside for the inline
/// pass: a stand-in the pass reads as one plain span (a backtick, U+E000, its index, U+E001, a
/// backtick) takes its place, and `keptCode` gives its content back when the span draws. The
/// stand-in never reaches the page. A span of several backticks drops one space from each end of
/// its content when both have one, as CommonMark does.
function keepCodeSpans(source: string): { text: string; codes: string[] } | undefined {
  const spans = codeSpans(source);
  if (!spans.length) return undefined;
  const codes: string[] = [];
  let text = "";
  let last = 0;
  for (const span of spans) {
    let code = source.slice(span.inner[0], span.inner[1]);
    if (span.run > 1 && code.length > 2 && code.startsWith(" ") && code.endsWith(" ") && code.trim())
      code = code.slice(1, -1);
    text += `${source.slice(last, span.start)}\`\uE000${codes.length}\uE001\``;
    codes.push(code);
    last = span.end;
  }
  return { text: text + source.slice(last), codes };
}

/// A code span's content: the span `keepCodeSpans` set aside when `raw` is its stand-in.
function keptCode(raw: string, opts: InlineOptions): string {
  const kept = opts.codes && /^\uE000(\d+)\uE001$/.exec(raw);
  return kept ? (opts.codes![Number(kept[1])] ?? raw) : raw;
}

const NO_FOLDERS: readonly string[] = [];

/// A link's label: inline Markdown, whose file names are its text, never chips of their own inside
/// the link's chip.
function linkLabel(source: string, opts: InlineOptions): ReactNode {
  return <ReplyFoldersContext.Provider value={NO_FOLDERS}>{renderInline(source, opts)}</ReplyFoldersContext.Provider>;
}

/** Render inline Markdown (code, bold, italic, strikethrough, links, line breaks). */
export function renderInline(source: string, outer: InlineOptions = {}): ReactNode[] {
  const refs: string[] = [];
  const kept = outer.commonmark && !outer.codes ? keepCodeSpans(source) : undefined;
  const text = capDataUrls(kept ? kept.text : source, refs);
  const withCodes = kept ? { ...outer, codes: kept.codes } : outer;
  const opts = refs.length ? { ...withCodes, dataRefs: refs } : withCodes;
  const out: ReactNode[] = [];
  let last = 0;
  let k = 0;
  for (const m of text.matchAll(INLINE_RE)) {
    if (m.index! > last) out.push(...proseText(text.slice(last, m.index), `t${k++}`, opts));
    const t = m[0];
    const inner = m[1] ? keptCode(t.slice(1, -1), opts) : "";
    const named = m[1] ? opts.started?.mentions.find((mention) => mention.text === inner) : undefined;
    if (named) out.push(<StartedSessionChip key={k++} mention={named} text={named.text} onOpen={opts.started!.open} />);
    else if (m[1]) {
      const path = codePath(inner);
      const code = (
        <code key={k++} className="cv-code">
          <SoftBroken text={inner} />
        </code>
      );
      // An agent link or a `HOST/NAME` (sessionRefs.ts): a link to the session when it is the
      // reader's (Leo, 2026-11-03: "these links aren't clickable"); a name stays code until then.
      const ref = path ? undefined : agentRef(inner);
      // A provider's file id in code is still one nobody here can open (chips/paths.ts).
      const foreign = path || ref ? undefined : foreignFileId(inner);
      out.push(
        foreign ? (
          <ForeignFileRef key={k++} id={foreign} />
        ) : ref ? (
          <SessionRefCode key={k++} text={inner} agentRef={ref} fallback={code} />
        ) : path ? (
          <PathChip key={k++} path={path} written={inner} label={lineLabel(path, inner)} />
        ) : isBareFileName(inner) ? (
          // A file name with no folder: its chip when it is in a folder the reply names.
          <SiblingFileChip key={k++} name={inner} fallback={code} />
        ) : (
          code
        ),
      );
    } else if (m[2]) out.push(<strong key={k++}>{renderInline(t.slice(2, -2), opts)}</strong>);
    else if (m[3]) out.push(<del key={k++}>{renderInline(t.slice(2, -2), opts)}</del>);
    else if (m[4]) out.push(<em key={k++}>{renderInline(t.slice(1, -1), opts)}</em>);
    else if (m[5]?.startsWith("!")) out.push(<InlineImage key={k++} source={t} opts={opts} />);
    else if (m[5]) {
      const lm = t.match(/^\[([^\]]+)\]\((.+)\)$/)!;
      const href = safeHref(lm[2]);
      // A local path is a path chip; a link the pane will not open draws as its text; a web
      // link is a chip with its site's mark (chips/LinkChips.tsx).
      const path = linkPath(lm[2]);
      const labelOpts = { ...opts, githubRepository: undefined, linkGithubReferences: false, started: undefined };
      // A link to a session (`cmux://session/<id>`) the open chat started opens that chat.
      const linked = /^[a-z][\w+.-]*:\/\/session\/([\w-]+)$/i.exec(lm[2])?.[1];
      const named = linked ? opts.started?.mentions.find((mention) => mention.sessionId === linked) : undefined;
      const app = href ? undefined : appHref(lm[2]);
      // An agent pointing at an open ask (`cmux://needs-you/<permissionId>`, needsYou/links.ts):
      // a chip that opens the header's Needs you list on it, so the ask is never restated. With the
      // list off (not installed from the App Store) it draws as its text, like a link the pane will not open.
      const ask = href ? undefined : needsYouTarget(lm[2]);
      if (ask && needsYouListOff()) out.push(<Fragment key={k++}>{linkLabel(lm[1], labelOpts)}</Fragment>);
      else if (ask)
        out.push(
          <button key={k++} type="button" className="cv-link is-needs-you" onClick={() => openNeedsYou(ask)}>
            <span className="acpmux-needs-you-dot" aria-hidden="true" />
            {linkLabel(lm[1], labelOpts)}
          </button>,
        );
      else if (named)
        out.push(<StartedSessionChip key={k++} mention={named} text={lm[1]} onOpen={opts.started!.open} />);
      else if (path) out.push(<PathChip key={k++} path={path} label={linkLabel(lm[1], labelOpts)} />);
      else if (app) {
        // A cmux app link: a plain anchor, so the click takes the host's link path (opened in the app).
        // One that names a chat or a place the page knows draws as its chip, with the author's label
        // (chips/CmuxLinkChip.tsx), as a bare link does (review of #38166).
        const label = linkLabel(lm[1], labelOpts);
        const anchor = (
          <a className="cv-link is-app" href={app}>
            {label}
          </a>
        );
        out.push(
          cmuxLinkTarget(app) ? (
            <CmuxLinkChip key={k++} href={app} label={label} fallback={anchor} />
          ) : (
            <Fragment key={k++}>{anchor}</Fragment>
          ),
        );
      }
      // A template (`${variant}.png`) names no file: its text.
      else if (!href && isTemplatePath(lm[2])) out.push(<Fragment key={k++}>{linkLabel(lm[1], labelOpts)}</Fragment>);
      else if (linkKind(lm[2]) === "file")
        out.push(
          <span key={k++} className="cv-link is-file">
            {(opts.linkIcon ?? linkIcon)(lm[2])}
            {linkLabel(lm[1], labelOpts)}
          </span>,
        );
      else if (!href) out.push(<Fragment key={k++}>{linkLabel(lm[1], labelOpts)}</Fragment>);
      else {
        const label = linkLabel(lm[1], labelOpts);
        const chip = (
          <UrlChip href={href} icon={linkKind(href) === "web" ? undefined : (opts.linkIcon ?? linkIcon)(href)}>
            {label}
          </UrlChip>
        );
        // cmux.com's agent link: the chat it names, with the author's label, once the page knows it.
        out.push(
          href.includes("/deeplink/") && cmuxLinkTarget(href) ? (
            <CmuxLinkChip key={k++} href={href} label={label} fallback={chip} />
          ) : (
            <Fragment key={k++}>{chip}</Fragment>
          ),
        );
      }
    } else if (m[6]) out.push(<br key={k++} />);
    else if (m[7]) out.push(<MathInline key={k++} tex={t.slice(2, -2).trim()} display />);
    else if (m[8])
      out.push(<MathInline key={k++} tex={t.startsWith("\\(") ? t.slice(2, -2).trim() : t.slice(1, -1)} />);
    else if (m[9]) out.push(t.slice(1));
    else if (m[10]) {
      const id = t.slice(2, -1);
      const number = opts.notes?.numbers.get(id);
      if (!number || !opts.notes) out.push(t);
      else {
        const anchor = opts.notes.anchor(id);
        out.push(
          <sup key={k++} className="cv-fnref">
            <button type="button" aria-describedby={anchor} onClick={() => scrollNote(document.getElementById(anchor))}>
              {number}
            </button>
          </sup>,
        );
      }
    }
    last = m.index! + t.length;
  }
  if (last < text.length) out.push(...proseText(text.slice(last), `t${k++}`, opts));
  return out;
}

// Native smooth scroll can paint one queued compositor step after cancellation. Transcript
// footnotes use the shared runner so manual input stops them before the next painted frame.
// A note inside its own scrolling panel (a capped tool result) is first brought into view
// there, at once, as scrollIntoView would; then the transcript rides to it.
function scrollNote(note: HTMLElement | null) {
  if (!note) return;
  const node = note.closest<HTMLElement>(".acpmux-scroll");
  if (!node) return note.scrollIntoView({ block: "nearest", behavior: noteScroll() });
  for (let inner = note.parentElement; inner && inner !== node; inner = inner.parentElement) {
    if (inner.scrollHeight <= inner.clientHeight) continue;
    const overflow = inner.ownerDocument.defaultView?.getComputedStyle(inner).overflowY;
    if (overflow !== "auto" && overflow !== "scroll") continue;
    inner.scrollTop = revealedTop(note, inner);
  }
  const target = () => revealedTop(note, node);
  animateScroll(
    node,
    target,
    noteScroll() === "auto" ? 0 : jumpDuration(target() - node.scrollTop),
    JUMP_CURVE,
    undefined,
    undefined,
    { explicit: true },
  );
}

/// Where `scroller` shows `note` by scrollIntoView's "nearest" rule, inside its scroll range.
function revealedTop(note: HTMLElement, scroller: HTMLElement): number {
  const end = scroller.scrollHeight - scroller.clientHeight;
  return Math.max(0, Math.min(end, scroller.scrollTop + nearest(note, scroller)));
}

/// How far `scroller` must move to show `note`, by scrollIntoView's "nearest" rule.
function nearest(note: HTMLElement, scroller: HTMLElement): number {
  const box = note.getBoundingClientRect();
  const top = scroller.getBoundingClientRect().top + scroller.clientTop;
  const paddingBottom =
    Number.parseFloat(scroller.ownerDocument.defaultView?.getComputedStyle(scroller).scrollPaddingBottom ?? "0") || 0;
  const bottom = top + scroller.clientHeight - paddingBottom;
  const visibleHeight = Math.max(0, bottom - top);
  const above = box.top < top;
  const below = box.bottom > bottom;
  if (above && below) return 0;
  if (above) return box.height <= visibleHeight ? box.top - top : box.bottom - bottom;
  if (below) return box.height <= visibleHeight ? box.bottom - bottom : box.top - top;
  return 0;
}

/// How a footnote reference scrolls to its note: a glide, or with cmux's animations off
/// (ui.animations) or the system's Reduce Motion, in one frame, as Jump to latest does (hq#3581).
function noteScroll(): ScrollBehavior {
  const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  return reduce ? "auto" : "smooth";
}

/// `![alt](src)`: a data URL image draws inline, and a click opens it in the image viewer; a web
/// image the pane cannot load draws as a link to it, named by its alt text or file name.
export function InlineImage({ source, opts }: { source: string; opts: InlineOptions }) {
  const [, alt = "", written = ""] = source.match(/^!\[([^\]]*)\]\((.+)\)$/) ?? [];
  const src = written.startsWith(DATA_REF) ? (opts.dataRefs?.[Number(written.slice(DATA_REF.length))] ?? "") : written;
  if (opts.overBudget?.has(src)) return <OversizedImage alt={alt} opts={opts} />;
  if (src === OVERSIZED_DATA_URL || (INLINE_IMAGE.test(src) && src.length > MAX_DATA_URL_LENGTH))
    return <OversizedImage alt={alt} opts={opts} />;
  if (INLINE_IMAGE.test(src)) return <OpenableImage src={src} alt={alt} thumb />;
  // An image only its provider opens (`sediment://…`) is named as that, never a broken image.
  const foreign = foreignFileId(src);
  if (foreign) return <ForeignFileRef id={foreign} />;
  const name = alt || src.split(/[?#]/)[0]!.split("/").filter(Boolean).at(-1) || src;
  const labelOpts = { ...opts, githubRepository: undefined, linkGithubReferences: false, started: undefined };
  const href = safeHref(src);
  const fallback = !href ? (
    <span className="cv-link is-image">
      <ImageIcon size={16} className="cv-link__icon" />
      {linkLabel(name, labelOpts)}
    </span>
  ) : (
    <a className="cv-link is-image" href={href} rel="noreferrer">
      <ImageIcon size={16} className="cv-link__icon" />
      {linkLabel(name, labelOpts)}
    </a>
  );
  // A file inside the session's folders, or a web image, loads through the host (D5).
  return <ReplyImage src={src} alt={alt} fallback={fallback} thumb />;
}

/// A data URL image over MAX_DATA_URL_LENGTH: its alt text (or "Image too large to show") with the
/// image mark, never the URL itself.
function OversizedImage({ alt, opts }: { alt: string; opts: InlineOptions }) {
  const t = useT();
  return (
    <span
      className="cv-link is-image"
      /* tooltip-allow: why the image does not show */ title={t("markdown.imageTooLarge")}
    >
      <ImageIcon size={16} className="cv-link__icon" />
      {alt
        ? renderInline(alt, { ...opts, githubRepository: undefined, linkGithubReferences: false })
        : t("markdown.imageTooLarge")}
    </span>
  );
}
