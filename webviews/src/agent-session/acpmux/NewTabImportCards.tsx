// The New Tab page's import cards, in the page's notice slot (App.tsx): only a Chief's sign-in
// requests (the host never pops up what a scan found; that stays in Settings > Import).
// A button goes back as `importCards.act {id, action}`.
import { ImportCards } from "../../ui/ImportCards";
import { useImportCards } from "./importCards";

export function NewTabImportCards({ onAction }: { onAction: (id: string, action: string) => void }) {
  const list = useImportCards();
  if (!list || list.cards.length === 0) return null;
  return (
    <div data-new-tab-import-cards="" style={{ width: "min(100%, 720px)", margin: "12px auto 0" }}>
      <ImportCards list={list} layout="row" onAction={onAction} />
    </div>
  );
}
