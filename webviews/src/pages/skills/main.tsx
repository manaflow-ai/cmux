import { createPageClient, type PageClient } from "../shared/pageClient";
import { createRoot } from "react-dom/client";
import { SkillsPage } from "./SkillsPage";
import { MockSkillsProvider } from "./mockProvider";
import "../shared/pageBase.css";
import "./styles.css";

export function mountSkillsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): void {
  createRoot(root).render(<SkillsPage client={client} />);
}
function defaultClient(): PageClient | null {
  return createPageClient(
    new URLSearchParams(location.search).has("mock")
      ? () => new MockSkillsProvider()
      : undefined,
  );
}
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "skills")
  mountSkillsPage(root);
