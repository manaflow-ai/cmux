import { createContext, useContext, type ReactNode } from "react";
import type { Presentation } from "../chatDisplay";
import "./messagesPresentation.css";

export const PresentationContext = createContext<Presentation>("transcript");

/** Keep the normal Markdown renderer, media and streaming inside the shared prompt glass. */
export function AssistantPresentation({ children }: { children: ReactNode }) {
  const presentation = useContext(PresentationContext);
  return presentation === "messages" ? (
    <div className="cv-user__bubble ui-glass cv-assistant-bubble">{children}</div>
  ) : (
    children
  );
}
