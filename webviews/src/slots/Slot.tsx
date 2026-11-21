// `<Slot>`: draws the variant the theme selects for one slot (registry.ts), with no element of its own,
// so the default variant's markup is exactly what the surface drew before it had a slot. A variant
// other than the default draws inside an error boundary of this slot alone: if it throws, the
// default draws in its place and the rest of the surface (the chat) keeps going.
import { Component, type ReactNode } from "react";
import { reportSlotFailure, slotVariant, useSlotVariant, type SlotDefinition } from "./registry";

type BoundaryProps = { slotId: string; variant: string; fallback: ReactNode; children: ReactNode };

/** Catches one variant's render error; keyed by the variant, so a newly selected one gets a fresh try. */
class SlotBoundary extends Component<BoundaryProps, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  componentDidCatch(error: unknown): void {
    reportSlotFailure(this.props.slotId, this.props.variant, error);
  }

  render(): ReactNode {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

export function Slot<Props extends object>({ slot, props }: { slot: SlotDefinition<Props>; props: Props }) {
  const selected = useSlotVariant(slot as SlotDefinition<unknown>);
  const variant = slotVariant(slot, selected);
  const fallback = slotVariant(slot, slot.defaultVariant);
  if (!variant || !fallback) return null;
  const Default = fallback.component;
  // The default draws bare: the surface's own markup, and its errors stay the surface's, as before slots.
  if (variant.id === slot.defaultVariant) return <Default {...props} />;
  const Chosen = variant.component;
  return (
    <SlotBoundary key={variant.id} slotId={slot.id} variant={variant.id} fallback={<Default {...props} />}>
      <Chosen {...props} />
    </SlotBoundary>
  );
}
