// What every transcript row renderer gets (App.tsx VirtualTranscript draws each row with the
// registry's renderer for its kind, rows/registry.ts), and the registry's shape.
import React from "react";
import type { AcpmuxRow } from "../model";

export type MeasurableRenderer = React.ComponentType<RowProps> & {
  measure?: (row: AcpmuxRow, width: number) => number;
};
export type NativeRegistry = Record<string, MeasurableRenderer>;
/// `onOpenDiff` opens the changes of the turn holding `rowId`, at `path` when given; focus
/// returns to `opener` when the view closes.
export type OpenDiff = (rowId: string, path?: string, opener?: HTMLElement) => void;
export type RowProps = {
  row: AcpmuxRow;
  sessionId?: string;
  onToggleActivity: (id: string) => void;
  expanded: boolean;
  controls?: string;
  onOpenDiff?: OpenDiff;
  githubRepository?: string;
};
