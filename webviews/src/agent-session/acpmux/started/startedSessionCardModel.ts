import { createContext, useContext } from "react";
import { type SessionMention } from "./startedSessions";

/// What a reply's name chips link: the chats the open chat started (by title and id) and every
/// other listed session (by its full id, sessionHover.ts `withSessionIds`), and how to open one. Empty
/// with started session cards off, so a reply draws as it always did.
export type StartedMentions = { mentions: readonly SessionMention[]; open(sessionId: string): void };
export const NO_MENTIONS: StartedMentions = { mentions: [], open: () => undefined };
export const StartedMentionsContext = createContext<StartedMentions>(NO_MENTIONS);
export const useStartedMentions = () => useContext(StartedMentionsContext);
