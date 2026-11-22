// How a later part of a running turn's long run is named (runParts.ts), for the modules that only
// need to know one when they see it: Find (chatFind.ts), the row estimate (model.ts) and the row's
// frame (VirtualTranscript.tsx), which give it the room the run had between two of its entries.
import type { AcpmuxRow } from "../model";

/// The id suffix of a later part of a running turn's long run: the run draws as rows of a few
/// cards each, which name the rows it came from in `joined`.
export const RUN_PART = ":part:";

/// Whether `row` is a later part of a long run: it starts where the run's flex gap
/// (`.cv-tools`, conversation.css) stood between two of its entries, and keeps that room above it.
export const isRunPart = (row: Pick<AcpmuxRow, "id">) => row.id.includes(RUN_PART);
