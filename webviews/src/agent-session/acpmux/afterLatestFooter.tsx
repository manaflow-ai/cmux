/// The transcript's after-latest footer: the card, then the tray. None when both are absent, since
/// an empty footer still takes the composer's room below the transcript and shortens it.
export function afterLatestFooter(card: React.ReactNode, tray: React.ReactNode): React.ReactNode | undefined {
  if (card == null && tray == null) return undefined;
  return (
    <>
      {card}
      {tray}
    </>
  );
}
