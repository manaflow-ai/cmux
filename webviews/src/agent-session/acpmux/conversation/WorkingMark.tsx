// The small animated mark at the start of a running turn's line ("Thinking", "Working for", the
// call in flight), as Claude desktop draws one: three dots that pulse in turn in the accent color.
// Drawn only; with Reduce Motion on they hold still (conversation.css).
export function WorkingMark() {
  return (
    <span className="cv-working-mark" aria-hidden="true">
      <span />
      <span />
      <span />
    </span>
  );
}
