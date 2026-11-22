// Which Chief sent this chat's prompts on the person's behalf (managedBy.ts `chiefOf`): a prompt
// the Chief sent draws a small avatar and "Sent from <Chief>" above its bubble, as ChatGPT marks a
// message its agent sent (Leo, 2026-11-02: "this is what the chatgpt dot does"). App.tsx provides
// it around the live transcript; elsewhere the line names the default Chief.
import { createContext, useContext } from "react";
import { DEFAULT_CHIEF } from "../managedBy";

export const TranscriptChief = createContext<string | undefined>(undefined);

/** The participant id of the Chief that sent this transcript's Chief prompts. */
export function useTranscriptChief(): string {
  return useContext(TranscriptChief) ?? DEFAULT_CHIEF;
}
