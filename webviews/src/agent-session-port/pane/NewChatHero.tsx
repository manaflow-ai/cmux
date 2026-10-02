// The new chat page (home.png, new-chat.png): the mark and "What should we build in
// <project>?" centered, the composer with its context bar docked at the bottom.
import type { ReactNode } from "react";
import { EmptyState } from "../shell/Main";

export function NewChatHero({ project, composer }: { project?: string; composer: ReactNode }) {
  return (
    <div className="pt-hero">
      <EmptyState project={project ?? null} style={{ position: "static" }} />
      <div className="pt-hero__dock">{composer}</div>
    </div>
  );
}
