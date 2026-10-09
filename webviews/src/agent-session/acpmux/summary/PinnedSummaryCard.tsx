// Stub (red commit): the pinned summary card.
import type { AcpmuxRow } from "../model";
import type { SummarySectionInput } from "./summaryRows";

export type SummaryCardProps = {
  rows: readonly AcpmuxRow[];
  project?: string;
  folder?: string;
  sections?: readonly SummarySectionInput[];
  onOpenOutput?: (path: string) => void;
  onOpenChanges?: () => void;
  onAddSource?: () => void;
  onOpenImage?: (src: string, alt: string) => void;
};

export function PinnedSummaryCard(_props: SummaryCardProps) {
  return null;
}
