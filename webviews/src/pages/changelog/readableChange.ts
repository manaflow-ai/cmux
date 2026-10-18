// A commit subject or release line as a person reads it. Stub: the tests come first.

export interface ReadableChange {
  title: string;
  internal: boolean;
}

export function readableChange(subject: string): ReadableChange {
  return { title: subject, internal: false };
}

export function shortTitle(text: string, _limit = 60): string | undefined {
  return text;
}
