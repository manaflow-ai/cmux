export function escapeMarkdownLabel(label: string): string {
  return label.replace(/([\\[\]])/g, "\\$1");
}

export function escapeMarkdownDestination(destination: string): string {
  return encodeURI(destination).replace(/([\\()])/g, "\\$1");
}
