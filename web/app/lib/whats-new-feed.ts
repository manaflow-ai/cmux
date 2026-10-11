import type { WhatsNewDocument } from "./whats-new";

function escape(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function title(document: WhatsNewDocument): string {
  return `cmux ${document.channel === "nightly" ? "Nightly " : ""}${document.version}: ${document.headline.en}`;
}

/** An Atom feed of What's New documents (English), one entry per release or nightly. */
export function whatsNewAtomFeed(documents: WhatsNewDocument[], origin: string): string {
  const updated = documents[0] ? `${documents[0].date}T00:00:00Z` : "1970-01-01T00:00:00Z";
  const entries = documents.map((document) => {
    const link = `${origin}/whats-new${document.channel === "nightly" ? "" : `/${document.version}`}`;
    const items = document.entries
      .map((entry) => `<li><strong>${escape(entry.title.en)}</strong>: ${escape(entry.summary.en)}</li>`)
      .join("");
    return [
      "  <entry>",
      `    <id>${origin}/whats-new/${escape(document.version)}</id>`,
      `    <title>${escape(title(document))}</title>`,
      `    <link href="${escape(link)}"/>`,
      `    <updated>${document.date}T00:00:00Z</updated>`,
      `    <category term="${document.channel}"/>`,
      `    <content type="html">${escape(`<p>${escape(document.headline.en)}</p><ul>${items}</ul>`)}</content>`,
      "  </entry>",
    ].join("\n");
  });
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<feed xmlns="http://www.w3.org/2005/Atom">',
    `  <id>${origin}/whats-new</id>`,
    "  <title>What's New in cmux</title>",
    `  <link href="${origin}/whats-new"/>`,
    `  <link rel="self" href="${origin}/whats-new/feed.xml"/>`,
    `  <updated>${updated}</updated>`,
    ...entries,
    "</feed>",
    "",
  ].join("\n");
}
