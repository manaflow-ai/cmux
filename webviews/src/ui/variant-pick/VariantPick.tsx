import type { ReactNode } from "react";
export interface VariantOption { id: string; label: string; preview?: ReactNode }
export interface VariantPickProps {
  options: readonly VariantOption[];
  recommendedId?: string;
  currentPick: string | null;
  onPick(id: string): void | Promise<void>;
}
export function VariantPick({ options }: VariantPickProps) {
  return <div>{options.map(option => <button key={option.id}>{option.label}</button>)}</div>;
}
