// One panel beside the chat (labs chatViewer, Lucas 2026-10-19): Files and Thread details side by
// side looked wrong. Until both live in one right sidebar, an open viewer (Files, a file, Changes)
// hides Thread details, and the Thread details button closes the viewer and shows the details.

/// The summary card as its header button sees it, while `viewerOpen` decides which panel shows.
export function viewerOrDetails<Card extends { shown: boolean; toggle(): void; show(): void }>(
  card: Card,
  viewerOpen: boolean,
  closeViewer: () => void,
): Card {
  if (!viewerOpen) return card;
  return {
    ...card,
    shown: false,
    toggle: () => {
      closeViewer();
      card.show();
    },
  };
}
