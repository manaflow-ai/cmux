// home-messages/sheets/RecipientField (New Message's To: field) with N contacts in its idle list (the
// Chiefs and the team, in sections), the page owning the draft as NewMessage.tsx does.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../../src/pages/shared/i18n";
import { RecipientField } from "../../../src/pages/home-messages/sheets/RecipientField";
import { EMPTY_DRAFT, type HomeContact, type RecipientDraft } from "../../../src/pages/home-messages/sheets/recipients";
import { caseItems, type VisibleListCase } from "./case";

const strings = createStrings({ en: { "home.list.section.chiefs": "Chiefs", "home.compose.section.team": "Team" } }, [
  "en",
]);

const contactsOf = (n: number): HomeContact[] =>
  caseItems(n).map((item, index) => ({ id: item.id, name: item.label, source: index < 3 ? "agent" : "team" }));

let changeOne = () => {};

function CaseRecipientField({ n }: { n: number }) {
  const [contacts, setContacts] = useState(() => contactsOf(n));
  const [draft, setDraft] = useState<RecipientDraft>(EMPTY_DRAFT);
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setContacts((previous) =>
        previous.map((contact, index) => (index === 4 ? { ...contact, name: `${contact.name}!` } : contact)),
      );
  }, []);
  return (
    <RecipientField
      strings={strings}
      draft={draft}
      onDraft={setDraft}
      contacts={contacts}
      idle={contacts}
      onDone={() => {}}
      onEscape={() => {}}
    />
  );
}

const recipientFieldCase: VisibleListCase = {
  mount(root, n) {
    flushSync(() => createRoot(root).render(<CaseRecipientField n={n} />));
    const list = () => root.querySelector<HTMLElement>(".hm-suggestions-list")!;
    return {
      rowSelector: '[role="option"]',
      // ui/Listbox's ListboxRow wraps each row; SuggestionRowView draws it.
      rowComponents: ["ListboxRow", "SuggestionRowView"],
      scroller: list,
      list,
      filter: () => root.querySelector<HTMLElement>(".hm-to-input")!,
      changeOne: () => changeOne(),
    };
  },
};
export default recipientFieldCase;
