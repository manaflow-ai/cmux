// Tells the app host while any composer holds text or files the person has not sent: the host's
// `draft` keep reason (`cmux.page.keepAlive`, PageKeepReasons). Nothing stores a composer's text,
// so the docked Channels view is never let go while it is hidden with one (HomeDockView,
// feature `memoryDiscardSidebarSections`), as Chrome never discards a tab with form input
// (components/performance_manager/policies/page_discarding_helper.cc, kFormInteractions).
import { createContext, useContext, useEffect } from "react";
import { PageKeepAlive, type PageClient } from "../shared/pageClient";

/** The page's composers that hold unsent input, as one `draft` reason for the host. */
export class ComposerDrafts {
  private readonly holding = new Set<symbol>();
  private readonly keepAlive: PageKeepAlive;

  constructor(host: PageClient | null) {
    this.keepAlive = new PageKeepAlive(host);
  }

  /** Whether some composer holds unsent input now. */
  get held(): boolean {
    return this.holding.size > 0;
  }

  /** One composer holds unsent input until the returned function runs. */
  hold(): () => void {
    const token = Symbol("composer");
    this.holding.add(token);
    this.keepAlive.set("draft", true);
    return () => {
      this.holding.delete(token);
      this.keepAlive.set("draft", this.held);
    };
  }
}

/** The page's drafts; absent in a browser or the gallery, where no host keeps the page. */
export const ComposerDraftsContext = createContext<ComposerDrafts | undefined>(undefined);

/** Reports this composer's unsent input (`held`) to the page's drafts while it lasts. */
export function useComposerDraft(held: boolean): void {
  const drafts = useContext(ComposerDraftsContext);
  useEffect(() => (held && drafts ? drafts.hold() : undefined), [drafts, held]);
}
