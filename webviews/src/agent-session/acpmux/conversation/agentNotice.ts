// A tool's or reconciler's notice to a chat (manaflow-ai/cmuxterm-hq#6380): a base-red watch's
// FIRE, an autoland's LANDED, an outbox relay's warning. acpmux stamps it on the prompt's
// `user_message` / `queued` record as provenance kind `notice` (prompt_provenance.rs `marked`):
// `{kind: "notice", from: "fromAgent", fromName: SENDER, to, notice: {sender, host?, severity, title,
// links?}}`. The prompt's text is what the model reads, rendered by the sending CLI:
//
//   [notice from base-red-watch on ci-mini-3 · FIRE] cmux-next fast tier failed on 3 PRs
//   <body>
//   Links: https://github.com/manaflow-ai/cmux/pull/32827 (#32827), ...
//
// (` · WARN` for a warning, no tag for info; `on HOST` only with a host; the Links line only with
// links.) The transcript draws it as one received line (IncomingMessageCard.tsx): the severity's
// mark, the sender, its machine, the title; the body behind the chevron without that head or the
// Links line, which the line and the links already say.
//
// Before senders switch to `acpmux send --notice`, tell-coordinator (leo-workspace
// tools/coord_inbox.py `deliver`) sends `[tell-coordinator from SENDER on HOST] FIRE …` as plain
// text through `acpmux send` at a shell; `legacyNotice` reads that head (only from a shell's or the
// outbox's `acpmux send`, never a prompt the person typed in the pane) so today's pages read too.

export type NoticeSeverity = "info" | "warn" | "fire";
export type NoticeLink = { url: string; label?: string };

export type AgentNotice = {
  sender: string;
  host?: string;
  severity: NoticeSeverity;
  title: string;
  links: readonly NoticeLink[];
};

const SEVERITIES: readonly string[] = ["info", "warn", "fire"];
/// A host name as acpmux accepts one: letters, digits, `.`, `-` or `_`, 1 to 64.
const HOST = /^[A-Za-z0-9._-]{1,64}$/;

const line = (value: unknown, max: number): string | undefined => {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text && text.length <= max ? text : undefined;
};

/// The notice a `notice` provenance carries, or undefined when it names no sender, severity or
/// title (an older or broken record: the prompt then reads as its sender's message).
export function provenanceNotice(provenance: Record<string, unknown>): AgentNotice | undefined {
  const raw = provenance.notice;
  if (!raw || typeof raw !== "object") return undefined;
  const notice = raw as Record<string, unknown>;
  const sender = line(notice.sender, 64) ?? line(provenance.fromName, 64);
  const title = line(notice.title, 200);
  const severity = typeof notice.severity === "string" && SEVERITIES.includes(notice.severity) ? notice.severity : "";
  if (!sender || !title || !severity) return undefined;
  const host = typeof notice.host === "string" && HOST.test(notice.host) ? notice.host : undefined;
  const links = Array.isArray(notice.links)
    ? notice.links.flatMap((link): NoticeLink[] => {
        const url = (link as { url?: unknown } | null)?.url;
        if (typeof url !== "string" || !/^https:\/\/\S+$/.test(url)) return [];
        const label = line((link as { label?: unknown }).label, 64);
        return [{ url, ...(label && { label }) }];
      })
    : [];
  return { sender, ...(host && { host }), severity: severity as NoticeSeverity, title, links: links.slice(0, 16) };
}

/// The rendered head's first line: `[notice from SENDER( on HOST)?( · FIRE| · WARN)?] TITLE`.
const RENDERED_HEAD =
  /^\[notice from ([\w.@/:-]{1,64})(?: on ([A-Za-z0-9._-]{1,64}))?(?: · (FIRE|WARN))?\][ \t]+(\S[^\n]*)$/;
/// The rendered Links line: `Links: URL (LABEL), URL, …`.
const LINKS_LINE = /^Links:[ \t]+(https:\/\/\S+.*)$/;
/// One link of the Links line: its URL (parentheses in it kept), then its label in parentheses.
const LINK = /^(https:\/\/\S+?)(?: \(([^\n]{1,64})\))?$/;

/// The body of a notice prompt: its text without the rendered head line and the Links line, which
/// the row draws itself. Text in no such form is the body as it is.
export function noticeBody(text: string): string {
  const lines = text.trim().split("\n");
  if (lines[0] && RENDERED_HEAD.test(lines[0])) lines.shift();
  if (lines.length && LINKS_LINE.test(lines.at(-1)!.trim())) lines.pop();
  return lines.join("\n").trim();
}

/// A notice in the text alone, as the sending CLI renders it (an older acpmux kept no provenance),
/// with its body; undefined when the text does not start with that head.
export function renderedNotice(text: string): { notice: AgentNotice; body: string } | undefined {
  const lines = text.trim().split("\n");
  const head = RENDERED_HEAD.exec(lines[0] ?? "");
  if (!head) return undefined;
  const [, sender, host, tag, title] = head as unknown as [
    string,
    string,
    string | undefined,
    string | undefined,
    string,
  ];
  const last = lines.length > 1 ? LINKS_LINE.exec(lines.at(-1)!.trim()) : null;
  // Links are `, `-separated, each starting https://, so a comma or parenthesis inside a URL stays.
  const links = last
    ? last[1]!.split(/, (?=https:\/\/)/).flatMap((part) => {
        const link = LINK.exec(part.trim());
        return link ? [{ url: link[1]!, ...(link[2] && { label: link[2] }) }] : [];
      })
    : [];
  return {
    notice: {
      sender,
      ...(host && { host }),
      severity: tag === "FIRE" ? "fire" : tag === "WARN" ? "warn" : "info",
      title: title.trim(),
      links,
    },
    body: noticeBody(text),
  };
}

/// tell-coordinator's head (coord_inbox.py `deliver`): `[tell-coordinator from SENDER on HOST(, sent
/// to X)?(, re Y)?] TEXT`.
const TELL_HEAD =
  /^\[tell-coordinator from ([\w.@/:-]{1,64}) on ([A-Za-z0-9._-]{1,64})(?:, [^\]\n]*)?\][ \t]+(\S[\s\S]*)$/;
/// The severity word a page starts with (base_red_watch.py: `FIRE …`, `WARN …`), and what follows it.
const SEVERITY_LEAD = /^(FIRE|WARN)\b[ \t]*[:!—–-]?[ \t]*(\S[\s\S]*)$/;

/// tell-coordinator's message: a page that starts FIRE or WARN is a notice (its first sentence the
/// title, the rest the body); any other is its sender's message, the head dropped.
export function legacyNotice(
  text: string,
): { notice: AgentNotice; body: string } | { sender: string; host: string; text: string } | undefined {
  const head = TELL_HEAD.exec(text.trim());
  if (!head) return undefined;
  const [, sender, host, rest] = head as unknown as [string, string, string, string];
  const lead = SEVERITY_LEAD.exec(rest.trim());
  if (!lead) return { sender, host, text: rest.trim() };
  const severity: NoticeSeverity = lead[1] === "FIRE" ? "fire" : "warn";
  const words = lead[2]!;
  const first = words.split("\n", 1)[0]!;
  // The first sentence: up to `.`, `!` or `?` before a space or the line's end.
  const sentence = /^(.+?)[.!?](?=\s|$)/.exec(first)?.[1] ?? first;
  const title = sentence.trim().length <= 200 ? sentence.trim() : first.trim();
  const body = words
    .slice(words.indexOf(sentence) + sentence.length)
    .replace(/^[.!?]/, "")
    .trim();
  return { notice: { sender, host, severity, title, links: [] }, body };
}

/// Automated notices that older senders put in a prompt as plain text, with nothing in the record to
/// say so: the head each starts with, and the sender its line names. Leo, 2026-11-03, on
/// `[stall-reconciler] #31356 conflicts with main …` drawn as his own bubble: asked whether they could
/// show "as a quiet, collapsed row, like the background-task replies", he said "yeah let's"; and, on
/// hiding such things, "well there are cases (rare) that you would want to see it". So each is a
/// notice's line that opens to its whole text, never hidden. Read only where the prompt did not come
/// from the pane (`acpmux send` at a shell or its outbox, an adopted or watched Claude session's
/// history); a sender that can marks its prompt itself (`acpmux send --notice`). Add a sender here
/// only with its exact head and a test (conversation/automatedNotice.test.ts).
export const AUTOMATED_NOTICE_HEADS: readonly { readonly sender: string; readonly head: RegExp }[] = [
  // leo-workspace tools/conflict_notice.py and the stall reconciler's other steers.
  { sender: "stall-reconciler", head: /^\[stall-reconciler\][ \t]*:?[ \t]*/ },
  // leo-workspace tools/spend_guard.py `nudge_text`.
  { sender: "spend-guard", head: /^Spend guard \(stall reconciler\):[ \t]*/ },
  // Claude Code's Stop hook that blocked the stop, its feedback the next prompt.
  { sender: "hook", head: /^Stop hook feedback:[ \t]*/ },
];

/// The title and body of a notice's words: its first line's first sentence (up to `.`, `!` or `?`
/// before a space or the line's end) is the title, what follows it the body. A first line too long
/// for a title is cut there, and the body keeps every word, so nothing is lost behind the chevron.
function titled(words: string): { title: string; body: string } {
  const all = words.trim();
  const first = all.split("\n", 1)[0]!.trim();
  const sentence = (/^(.+?)[.!?](?=\s|$)/.exec(first)?.[1] ?? first).trim();
  if (sentence.length <= 200)
    return {
      title: sentence,
      body: all
        .slice(sentence.length)
        .replace(/^[.!?]/, "")
        .trim(),
    };
  if (first.length <= 200) return { title: first, body: all.slice(first.length).trim() };
  return { title: `${first.slice(0, 199).trimEnd()}…`, body: all };
}

/// An automated notice in plain text (AUTOMATED_NOTICE_HEADS), as an info notice from its sender:
/// the title its first sentence, the body the rest. Undefined for text with no such head, or a head
/// with nothing after it.
export function automatedNotice(text: string): { notice: AgentNotice; body: string } | undefined {
  const trimmed = text.trim();
  for (const { sender, head } of AUTOMATED_NOTICE_HEADS) {
    const lead = head.exec(trimmed);
    if (!lead) continue;
    const words = trimmed.slice(lead[0].length).trim();
    if (!words) return undefined;
    const { title, body } = titled(words.replace(/^\n+/, ""));
    return { notice: { sender, severity: "info", title: title.replace(/\s+/g, " "), links: [] }, body };
  }
  return undefined;
}

/// A link's chip label: a GitHub pull request or issue reads `#32827`, an Actions run `run 1234567`
/// (its id cut to seven digits), else its label, else its host and the path's last part.
export function noticeLinkLabel(link: NoticeLink): string {
  const github = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:pull|issues)\/(\d+)(?:[/?#]|$)/.exec(link.url);
  if (github) return `#${github[1]}`;
  const run = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/actions\/runs\/(\d+)(?:[/?#]|$)/.exec(link.url);
  if (run) return `run ${run[1]!.length > 7 ? `${run[1]!.slice(0, 7)}…` : run[1]}`;
  if (link.label) return link.label;
  try {
    const url = new URL(link.url);
    const tail = url.pathname.split("/").filter(Boolean).at(-1);
    return tail ? `${url.host}/…/${tail}` : url.host;
  } catch {
    return link.url;
  }
}

/// A link destination as Markdown reads it whole: the characters that would end it or open another
/// (`(`, `)`, `<`, `>`, white space) percent-encoded, so a URL can never close its link early and
/// start another.
const destination = (url: string) =>
  url.replace(/[()<>\s]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`);

/// The notice's body as the opened line shows it: its text, then its links on one line, each named
/// as its chip would be (`#32827`, `run 1902234…`), so the body never repeats the rendered head or
/// the raw Links line. Inside the message text, never a chip row of its own (design/chat-transcript.md:
/// "Never draw a PR chip row or any link-chip row on transcript messages").
export function noticeMarkdown(body: string, links: readonly NoticeLink[]): string {
  if (!links.length) return body;
  const line = links
    .map((link) => `[${noticeLinkLabel(link).replace(/[[\]\\]/g, "\\$&")}](${destination(link.url)})`)
    .join(" · ");
  return body ? `${body}\n\n${line}` : line;
}

/// A notice's whole text as the transcript row keeps it for Find, Copy, export and the empty-row
/// check: its title, then what the opened line shows. Never empty: a notice of a title alone is
/// still a row.
export function noticeRowText(notice: AgentNotice, body: string): string {
  const rest = noticeMarkdown(body, notice.links);
  return rest ? `${notice.title}\n\n${rest}` : notice.title;
}
