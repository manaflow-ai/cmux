// The English strings of an app-health catalog (Localizable.xcstrings) as the string table the page
// i18n reads, for galleries: the generated server-cards table does not carry appHealth.* keys, so the
// gallery drew raw keys such as "appHealth.line.repairing".
type Catalog = { strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }> };

export function englishTable(raw: string): Record<string, Record<string, string>> {
  const catalog = JSON.parse(raw) as Catalog;
  const en: Record<string, string> = {};
  for (const [key, entry] of Object.entries(catalog.strings)) {
    const value = entry.localizations?.en?.stringUnit?.value;
    if (value !== undefined) en[key] = value;
  }
  return { en };
}
