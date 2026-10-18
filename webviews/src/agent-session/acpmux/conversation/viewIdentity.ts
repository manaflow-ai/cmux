import { createContext } from "react";

/// View state belongs to its chat and row, even when virtual rows remount (Lucas 2026-10-18).
export const ChatSessionContext = createContext("");
export const TranscriptRowContext = createContext<string | undefined>(undefined);
