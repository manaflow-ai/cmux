// A value kept from one render to the next in a holder (a `useRef` the caller owns), read and written
// as the component renders. Its own hook, in its own file: a component or hook that reads or writes a
// ref during render stays out of the React Compiler (useSessionInfo.tsx), and the holder is read here
// only through `keep`.
//
// `update` must answer the same for the same holder content and the same captured values (the
// compiler may reuse the last answer while neither changed): `keep` then leaves the holder as it was.

/// `update`'s answer for what `holder` kept last, kept for the next render.
export function useKept<T>(holder: { current: T }, update: (last: T) => T): T {
  return keep(holder, update);
}

function keep<T>(holder: { current: T }, update: (last: T) => T): T {
  const next = update(holder.current);
  holder.current = next;
  return next;
}
