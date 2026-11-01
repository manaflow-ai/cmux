/// Whether a row of older history fades in as it first mounts (OlderRowFade in App.tsx). Older
/// pages load several viewports ahead of the reader, so a row almost always mounts above the view,
/// before the reader reaches it: it draws in full ink at once, with no fade (Leo 2026-10-31: no
/// fade-in "unless it's the worst case", be optimistic). Only the worst case fades: the reader
/// reached the rows before their page arrived, so the row's first copy mounts inside the view.
export function olderRowFadesOnMount(
  row: { top: number; bottom: number },
  view: { top: number; bottom: number },
): boolean {
  return row.bottom > view.top && row.top < view.bottom;
}
