// A detailed workspace row's last message (#16688): the lead session's latest reply, one line.
export function RowPreview({ text }: { text: string }) {
  return <span className="proto-row-preview">{text}</span>;
}
