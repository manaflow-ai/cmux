/** Presentation of the two agent-mesh notifications that arrive in a transcript.
 *
 * The daemon owns the message text and (in the new protocol) the structured details.  This
 * module only turns that payload into the short collapsed line and its disclosure body.  Keeping
 * the result in a WeakMap matters for the virtualized transcript: unchanged rows are handed back
 * by the snapshot reducer and must not be reparsed on every render.
 */

export type LaneNoticeKind = "report" | "inbox";
export type LaneNoticeVerdict = "SHIP" | "BLOCK" | "FIX" | "HOLD";

export type LaneNoticeDelivery = {
  readonly sender: string;
  readonly text: string;
  readonly promptId?: string;
};
export type LaneNoticeThread = {
  readonly id: string;
  readonly sender: string;
  readonly preview?: string;
  readonly messages?: readonly LaneNoticeDelivery[];
  readonly label?: string;
  readonly promptIds?: readonly string[];
  readonly fromSession?: string;
  readonly count?: number;
};

export type LaneNotice = {
  readonly kind: LaneNoticeKind;
  readonly preview: string;
  readonly body: string;
  readonly details?: string;
  readonly verdict?: LaneNoticeVerdict;
  readonly threads?: readonly LaneNoticeThread[];
};

export type LaneNoticePayload = {
  readonly name: string;
  readonly text: string;
  readonly raw: string;
  readonly details?: unknown;
  /** True when acpmux has classified this payload as a lane report. */
  readonly report?: boolean;
  /** Structured inbox threads from acpmux's inbox_notice payload. */
  readonly noticeThreads?: readonly { readonly id: string; readonly sender: string }[];
};

const parsed = new WeakMap<object, LaneNotice | undefined>();

const REPORT_HEAD = /^(?:\[[^\]\n]+\]\s*)?lane report:\s*turn\s+(\d+)\s+ended,\s*([^.!\n]+)\.?/i;
const NEW_TURN_TAIL = /(?:^|\s)·\s*turn\s+\d+\s*,\s*(?:idle|running|working|ended|[\w -]+)\s*$/i;
const REVIEW = /Review\s*\([^)]*\):\s*(SHIP|BLOCK|FIX|HOLD)\s+at\s+([0-9a-f]{40})(?![0-9a-f])/i;
const NEW_VERDICT = /^\s*(SHIP|BLOCK|FIX|HOLD)\s+at\s+([0-9a-f]{12,40})(?![0-9a-f])/i;
const FINDING = /^\s*\[P([123])\]\s+(.+)$/i;
const INBOX_HEAD = /^(?:\[inbox\]\s+)?New messages from other agents(?:\s+in\s+\d+\s+threads?)?\.?/i;
const THREAD = /\(thread\s+([^\s)]+)\)/gi;
const FOOTER = /^\s*\(?acpmux sends this[^\n]*\)?\s*$/i;

function firstSentence(text: string): string {
  const line =
    text
      .split("\n")
      .map((part) => part.trim())
      .find(Boolean) ?? "";
  const sentence = line.match(/^(.+?[.!?])(?:\s|$)/)?.[1] ?? line;
  const compact = sentence.trim().replace(/\s+/g, " ");
  if (compact.length <= 120) return compact;
  return (
    compact
      .slice(0, 120)
      .replace(/\s+\S*$/, "")
      .trim() || compact.slice(0, 120)
  );
}

function detailsText(value: unknown, legacy: string[]): string | undefined {
  if (typeof value === "string" && value.trim()) return value.trim();
  if (value && typeof value === "object") return JSON.stringify(value, null, 2);
  return legacy.length ? legacy.join("\n") : undefined;
}

function reportNotice(message: LaneNoticePayload, legacy: boolean): LaneNotice {
  const lines = message.text.split("\n");
  const verdictText = message.text.replace(/^\s*\[[^\]\n]+\]\s*/, "");
  const review = REVIEW.exec(message.text) ?? NEW_VERDICT.exec(verdictText);
  const verdict = review?.[1]?.toUpperCase() as LaneNotice["verdict"] | undefined;
  const sha = review?.[2]?.slice(0, 12);
  const findings = lines.filter((line) => FINDING.test(line));
  const counts = (["P1", "P2", "P3"] as const).map(
    (level) => findings.filter((line) => line.trim().toUpperCase().startsWith(`[${level}]`)).length,
  );
  const countText = counts
    .map((count, index) => (count ? `${count} P${index + 1}` : ""))
    .filter(Boolean)
    .join(", ");
  const header = lines[0] ?? "";
  const signature = /^\[([^\]\n]+)\]\s*/.exec(header);
  const title = signature?.[1] === message.name ? header.slice(signature[0].length) : header;
  const lastMessage = lines.find((line) => /^\s*Last message:\s*/i.test(line))?.replace(/^\s*Last message:\s*/i, "");
  const firstBody = lines.slice(1).find((line) => {
    const trimmed = line.trim();
    return trimmed && !/^Session:|^Commits named:|^\(?(?:acpmux sends this)/i.test(trimmed) && !FOOTER.test(trimmed);
  });
  const first = firstSentence(lastMessage ?? firstBody ?? title);
  // These are the daemon's protocol tokens, not translated UI labels.
  const preview =
    legacy && verdict
      ? `${verdict} at ${sha}${countText ? ` · ${countText}` : ""}`
      : legacy
        ? first
        : title.replace(NEW_TURN_TAIL, "").trim();
  const bodyLines = lines
    .map((line, index) => (legacy && index === 0 ? "" : line.replace(/^\s*Last message:\s*/i, "")))
    .filter((line) => !/^(?:Session:|Commits named:)/i.test(line) && !FOOTER.test(line));
  const body = bodyLines.join("\n").trim();
  const legacyDetails = lines.filter((line) => /^(?:Session:|Commits named:)/i.test(line) || FOOTER.test(line));
  const details = detailsText(message.details, legacyDetails);
  return {
    kind: "report",
    preview,
    body,
    ...(verdict ? { verdict } : {}),
    ...(details ? { details } : {}),
  };
}

function inboxNotice(message: LaneNoticePayload): LaneNotice {
  const threads: LaneNoticeThread[] = [...(message.noticeThreads ?? [])];
  // Structured thread ids are authoritative; the text repeats them for older clients.
  const lines = message.text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!.trim();
    const match =
      /^-\s+(?:\[blocker\]\s+)?(\d+)\s+new\s+in\s+(.+?)\s+from\s+(.+?)(?:\s*:\s*(.*?))?\s*\(thread\s+([^\s)]+)\)/i.exec(
        line,
      );
    if (!match) continue;
    const [, countText, , fromText, inlinePreview, id] = match;
    const senderNames = fromText!
      .split(/,\s*/)
      .map((name) => name.trim())
      .filter(Boolean);
    const deliveries: LaneNoticeDelivery[] = [];
    if (inlinePreview?.trim()) {
      const sender = senderNames.at(-1) ?? "inbox";
      deliveries.push({ sender, text: inlinePreview.trim() });
    } else {
      let current: LaneNoticeDelivery | undefined;
      const flush = () => {
        if (current) deliveries.push(current);
        current = undefined;
      };
      for (let next = index + 1; next < lines.length && !/^\s*-\s+/.test(lines[next]!); next += 1) {
        const body = /^\s*>\s?(.*)$/.exec(lines[next]!);
        if (!body) continue;
        const content = body[1]!.trimEnd();
        if (!content.trim()) {
          if (current) current = { ...current, text: `${current.text}\n` };
          continue;
        }
        const signed = /^([^:]+):\s+(.+)$/.exec(content.trimStart());
        const knownSender = signed && senderNames.includes(signed[1]!.trim());
        if (knownSender) {
          flush();
          current = { sender: signed[1]!.trim(), text: signed[2]!.trim() };
        } else if (current) {
          current = { ...current, text: `${current.text}\n${content}` };
        } else {
          current = { sender: senderNames.at(-1) ?? "inbox", text: content.trim() };
        }
      }
      flush();
    }
    const existing = threads.find((thread) => thread.id === id);
    const messages = deliveries.length ? deliveries : existing?.messages;
    const sender = messages?.at(-1)?.sender ?? senderNames.at(-1) ?? existing?.sender ?? id!.replace(/^from:/, "");
    const preview = messages?.at(-1)?.text ?? existing?.preview;
    const next: LaneNoticeThread = {
      id: id!,
      sender,
      ...(preview ? { preview } : {}),
      ...(messages?.length ? { messages } : {}),
    };
    const at = threads.findIndex((thread) => thread.id === id);
    if (at >= 0) threads[at] = { ...threads[at], ...next };
    else threads.push(next);
    // The line's count may exceed the number of preview lines when older clients only expose a
    // single preview. Keep that one delivery; the count remains in the wrapper text.
    void countText;
  }
  if (!threads.length)
    for (const match of message.text.matchAll(THREAD)) {
      const id = match[1]!;
      const sender = id.replace(/^from:/, "").split("/pr:")[0]!;
      if (!threads.some((thread) => thread.id === id)) threads.push({ id, sender });
    }
  // The batch head supplies its localized count. A member previews who wrote, not the harness's instructions.
  const preview = threads.length
    ? [...new Set(threads.map((thread) => thread.sender).filter(Boolean))].join(", ")
    : firstSentence(message.text);
  return { kind: "inbox", preview, body: message.text.trim(), ...(threads.length ? { threads } : {}) };
}

export function laneNotice(message: LaneNoticePayload): LaneNotice | undefined {
  if (!message || typeof message !== "object") return undefined;
  const cached = parsed.get(message as object);
  if (cached !== undefined || parsed.has(message as object)) return cached;
  const text = message.text.trim();
  const legacy = REPORT_HEAD.exec(text);
  const report = Boolean(message.report) || Boolean(legacy) || NEW_TURN_TAIL.test(text.split("\n", 1)[0] ?? "");
  const isInbox = INBOX_HEAD.test(text) || INBOX_HEAD.test(message.raw.trim()) || message.name === "inbox";
  const result = isInbox ? inboxNotice(message) : report ? reportNotice(message, Boolean(legacy)) : undefined;
  parsed.set(message as object, result);
  return result;
}
