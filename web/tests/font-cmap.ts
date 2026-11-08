function tableOffset(font: Uint8Array, tag: string): number {
  const view = new DataView(font.buffer, font.byteOffset, font.byteLength);
  const tableCount = view.getUint16(4);
  for (let index = 0; index < tableCount; index += 1) {
    const recordOffset = 12 + index * 16;
    const recordTag = String.fromCharCode(
      font[recordOffset],
      font[recordOffset + 1],
      font[recordOffset + 2],
      font[recordOffset + 3],
    );
    if (recordTag === tag) return view.getUint32(recordOffset + 8);
  }
  throw new Error(`Font is missing its ${tag} table`);
}

function format4Supports(
  view: DataView,
  subtableOffset: number,
  codePoint: number,
): boolean {
  if (codePoint > 0xffff) return false;
  const segmentCount = view.getUint16(subtableOffset + 6) / 2;
  const endCodesOffset = subtableOffset + 14;
  const startCodesOffset = endCodesOffset + segmentCount * 2 + 2;
  const deltasOffset = startCodesOffset + segmentCount * 2;
  const rangeOffsetsOffset = deltasOffset + segmentCount * 2;

  for (let index = 0; index < segmentCount; index += 1) {
    const endCode = view.getUint16(endCodesOffset + index * 2);
    if (codePoint > endCode) continue;
    const startCode = view.getUint16(startCodesOffset + index * 2);
    if (codePoint < startCode) return false;

    const delta = view.getInt16(deltasOffset + index * 2);
    const rangeOffsetPosition = rangeOffsetsOffset + index * 2;
    const rangeOffset = view.getUint16(rangeOffsetPosition);
    if (rangeOffset === 0) return ((codePoint + delta) & 0xffff) !== 0;

    const glyphOffset =
      rangeOffsetPosition + rangeOffset + (codePoint - startCode) * 2;
    if (glyphOffset + 2 > view.byteLength) return false;
    const glyph = view.getUint16(glyphOffset);
    return glyph !== 0 && ((glyph + delta) & 0xffff) !== 0;
  }
  return false;
}

function format12Supports(
  view: DataView,
  subtableOffset: number,
  codePoint: number,
): boolean {
  const groupCount = view.getUint32(subtableOffset + 12);
  for (let index = 0; index < groupCount; index += 1) {
    const groupOffset = subtableOffset + 16 + index * 12;
    const startCode = view.getUint32(groupOffset);
    const endCode = view.getUint32(groupOffset + 4);
    if (codePoint < startCode) return false;
    if (codePoint <= endCode) {
      return view.getUint32(groupOffset + 8) + codePoint - startCode !== 0;
    }
  }
  return false;
}

export function fontSupportsCodePoint(
  font: Uint8Array,
  codePoint: number,
): boolean {
  const view = new DataView(font.buffer, font.byteOffset, font.byteLength);
  const cmapOffset = tableOffset(font, "cmap");
  const subtableCount = view.getUint16(cmapOffset + 2);

  for (let index = 0; index < subtableCount; index += 1) {
    const recordOffset = cmapOffset + 4 + index * 8;
    const subtableOffset = cmapOffset + view.getUint32(recordOffset + 4);
    const format = view.getUint16(subtableOffset);
    if (
      (format === 4 && format4Supports(view, subtableOffset, codePoint)) ||
      (format === 12 && format12Supports(view, subtableOffset, codePoint))
    ) {
      return true;
    }
  }
  return false;
}
