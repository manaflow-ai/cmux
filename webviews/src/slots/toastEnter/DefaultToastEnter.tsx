// `toast.enter` / `default`: the card as NoticeStack drew it before slots, with no element of its own
// (Slots.defaults.test.tsx compares it to the pre-slot JSX). Its arrival is the deck's (NoticeDeck.tsx).
import type { ToastEnterProps } from "./slot";

export function DefaultToastEnter({ children }: ToastEnterProps) {
  return <>{children}</>;
}
