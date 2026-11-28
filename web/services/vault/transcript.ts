export type TranscriptMessage = {
  readonly role: string;
  readonly text: string;
};

export class TranscriptLineParser {
  private pending = "";

  constructor(private readonly onMessage: (message: TranscriptMessage) => void) {}

  feed(chunk: string): void {
    if (!chunk) return;
    this.pending += chunk;
    const lines = this.pending.split(/\r?\n/);
    this.pending = lines.pop() ?? "";
    for (const line of lines) {
      this.parseLine(line);
    }
  }

  finish(): void {
    const finalLine = this.pending;
    this.pending = "";
    this.parseLine(finalLine);
  }

  private parseLine(line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      return;
    }

    const message = extractTranscriptMessage(parsed);
    if (message) this.onMessage(message);
  }
}

export function extractTranscriptMessages(jsonl: string): readonly TranscriptMessage[] {
  const messages: TranscriptMessage[] = [];
  const parser = new TranscriptLineParser((message) => messages.push(message));
  parser.feed(jsonl);
  parser.finish();
  return messages;
}

export function extractTranscriptMessage(value: unknown): TranscriptMessage | null {
  for (const candidate of messageCandidates(value)) {
    const role = stringProperty(candidate, "role");
    if (!role) continue;
    const text = extractText(candidate);
    if (!text) continue;
    return { role, text };
  }
  return null;
}

function messageCandidates(value: unknown): readonly Record<string, unknown>[] {
  if (!isRecord(value)) return [];
  const candidates: Record<string, unknown>[] = [value];
  if (isRecord(value.message)) candidates.push(value.message);
  if (isRecord(value.payload)) candidates.push(value.payload);
  return candidates;
}

function extractText(record: Record<string, unknown>): string | null {
  const directText = stringProperty(record, "text");
  if (directText) return directText;
  const content = record.content;
  if (typeof content === "string" && content.trim()) return content;
  if (Array.isArray(content)) {
    const parts = content
      .map((item) => (isRecord(item) && typeof item.text === "string" ? item.text : null))
      .filter((text): text is string => Boolean(text?.trim()));
    if (parts.length > 0) return parts.join("\n");
  }
  return null;
}

function stringProperty(record: Record<string, unknown>, key: string): string | null {
  const value = record[key];
  return typeof value === "string" && value.trim() ? value : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
