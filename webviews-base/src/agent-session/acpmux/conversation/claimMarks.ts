import type { ClaimCheck } from "../model";

/// A piece of prose: plain text, or a claim's phrase with its check.
export type ClaimPiece = string | { claim: ClaimCheck; text: string };

/// `text` cut at the phrases of `claims` (a reply's, model.ts `claims`), in reading order. A phrase
/// the text does not hold, as a whole, is not drawn: a claim the renderer split (across emphasis or
/// a link) gets no mark rather than a mark on part of it.
export function splitClaims(text: string, claims: readonly ClaimCheck[] | undefined): ClaimPiece[] {
  if (!claims?.length || !text) return [text];
  const hits: { start: number; end: number; claim: ClaimCheck }[] = [];
  for (const claim of claims) {
    let from = 0;
    for (;;) {
      const start = text.indexOf(claim.text, from);
      if (start < 0) break;
      const end = start + claim.text.length;
      if (!hits.some((hit) => start < hit.end && hit.start < end)) hits.push({ start, end, claim });
      from = end;
    }
  }
  if (!hits.length) return [text];
  hits.sort((a, b) => a.start - b.start);
  const out: ClaimPiece[] = [];
  let at = 0;
  for (const hit of hits) {
    if (hit.start > at) out.push(text.slice(at, hit.start));
    out.push({ claim: hit.claim, text: text.slice(hit.start, hit.end) });
    at = hit.end;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}
