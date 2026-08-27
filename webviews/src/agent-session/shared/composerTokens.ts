export type ComposerTokenInsertion = {
  text: string;
  cursor: number;
};

export function insertComposerToken(input: {
  text: string;
  selectionStart: number;
  selectionEnd: number;
  token: "@" | "$";
}): ComposerTokenInsertion {
  const start = clampOffset(input.selectionStart, input.text.length);
  const end = clampOffset(input.selectionEnd, input.text.length);
  const selectionStart = Math.min(start, end);
  const selectionEnd = Math.max(start, end);
  const prefix = input.text.slice(0, selectionStart);
  const suffix = input.text.slice(selectionEnd);
  const needsLeadingSpace = prefix.length > 0 && !/\s$/.test(prefix);
  const inserted = `${needsLeadingSpace ? " " : ""}${input.token}`;
  return {
    text: `${prefix}${inserted}${suffix}`,
    cursor: prefix.length + inserted.length,
  };
}

function clampOffset(value: number, length: number): number {
  if (!Number.isFinite(value)) {
    return length;
  }
  return Math.max(0, Math.min(length, value));
}
