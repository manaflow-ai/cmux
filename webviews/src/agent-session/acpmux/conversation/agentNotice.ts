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
  /// cmux's own notice (a background command's end): its sender is an internal component, named
  /// `cmux` on the line, and no chat of the list stands behind it.
  system?: true;
  /// How many more notices went in with this one (a digest of notices, incomingMessage.ts): the
  /// line names this one, the most severe, and counts the rest.
  more?: number;
};

const SEVERITIES: readonly string[] = ["info", "warn", "fire"];

/// The names cmux's own parts sign their notices with. The reader never sees them: cmux's
/// components are cmux to the person (user, 2026-11-09: "generally in gui we should not mention
/// stuff like \"acpmux\"").
const SYSTEM_SENDERS = new Set(["acpmux", "optchat", "cmux-tui", "cmuxd"]);

/// Whether a sender's name is one of cmux's own parts.
export const isSystemSender = (name: string) => SYSTEM_SENDERS.has(name.trim().toLowerCase());

/// The name a sender reads as: cmux's own parts read `cmux`, any other its own name.
export const shownSender = (name: string) => (isSystemSender(name) ? "cmux" : name);

/// A system notice's body as the reader sees it: without the `Task bg-…: COMMAND` line (the title
/// already names the command; the id is the model's handle) and the `(bg_output reads all of it.)`
/// hint, which names a tool only the model calls (acpmux hub/bg_notify.rs `end_body`).
export function shownNoticeBody(notice: AgentNotice, body: string): string {
  if (!notice.system) return body;
  const lines = body.split("\n");
  if (lines[0] && /^Task \S+: /.test(lines[0])) lines.shift();
  if (lines.length && /^\(bg_output reads all of it\.\)$/.test(lines.at(-1)!.trim())) lines.pop();
  return lines.join("\n").trim();
}

/// A notice signed by `sender`: cmux's own parts are marked and named `cmux`.
function signed(sender: string): Pick<AgentNotice, "sender" | "system"> {
  return isSystemSender(sender) ? { sender: "cmux", system: true } : { sender };
}
/// A host name as acpmux accepts one: letters, digits, `.`, `-` or `_`, 1 to 64.
const HOST = /^[A-Za-z0-9._-]{1,64}$/;

const line = (value: unknown, max: number): string | undefined => {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text && text.length <= max ? text : undefined;
};

/// A title as one line of at most `TITLE_MAX` characters. A longer one keeps its end (a
/// background command's `(exit 2)`) and loses the middle, cut with `…`: it is still the notice's.
const TITLE_MAX = 200;
function noticeTitle(value: unknown): string | undefined {
  const text = line(value, Number.MAX_SAFE_INTEGER);
  if (!text || text.length <= TITLE_MAX) return text;
  const end = titleParts(text).end;
  const keep = end ? ` ${end}` : "";
  return `${text.slice(0, TITLE_MAX - keep.length - 1).trimEnd()}…${keep}`;
}

/// A title split where its line may cut it: what it is about (`lead`, cut first), and the outcome in
/// parentheses that ends it (`(exit 2)`, `(signal 9)`), which the line always shows whole.
export function titleParts(title: string): { lead: string; end?: string } {
  const split = /^(.*\S)[ \t]+(\([^()\n]{1,80}\))$/.exec(title);
  return split ? { lead: split[1]!, end: split[2]! } : { lead: title };
}

/// The notice a `notice` provenance carries, or undefined when it names no sender, severity or
/// title (an older or broken record: the prompt then reads as its sender's message).
export function provenanceNotice(provenance: Record<string, unknown>): AgentNotice | undefined {
  const raw = provenance.notice;
  if (!raw || typeof raw !== "object") return undefined;
  const notice = raw as Record<string, unknown>;
  const sender = line(notice.sender, 64) ?? line(provenance.fromName, 64);
  const title = noticeTitle(notice.title);
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
  return {
    ...signed(sender),
    ...(host && { host }),
    severity: severity as NoticeSeverity,
    title,
    links: links.slice(0, 16),
  };
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
      ...signed(sender),
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
  return { notice: { ...signed(sender), host, severity, title, links: [] }, body };
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
