// Fixture for test/pane-english.test.ts: a type-only import ships no code, so it is not a finding.
import type { boardTitle } from "../board/Board";

export type Title = typeof boardTitle;
