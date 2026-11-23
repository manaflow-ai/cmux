// `chat.side` / `default`: the note BtwAside.tsx drew before slots, unchanged (btw.css
// `.acpmux-btw-note`; Slots.defaults.test.tsx compares it to the pre-slot JSX).
import type { SideProps } from "./slot";

export function DefaultSideNote({ children, label, pending }: SideProps) {
  return (
    <aside className="acpmux-btw-note" aria-label={label} aria-busy={pending} aria-live="polite">
      {children}
    </aside>
  );
}
