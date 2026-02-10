import type { Metadata } from "next";
import fs from "fs";
import path from "path";

export const metadata: Metadata = {
  title: "Changelog",
  description: "Release notes and version history for cmux",
};

interface ChangelogSection {
  heading: string;
  items: string[];
}

interface ChangelogVersion {
  version: string;
  date: string;
  intro?: string;
  sections: ChangelogSection[];
}

function parseChangelog(markdown: string): ChangelogVersion[] {
  const versions: ChangelogVersion[] = [];
  let current: ChangelogVersion | null = null;
  let currentSection: ChangelogSection | null = null;

  for (const line of markdown.split("\n")) {
    const versionMatch = line.match(/^## \[(.+?)\] - (.+)$/);
    if (versionMatch) {
      if (current) versions.push(current);
      current = {
        version: versionMatch[1],
        date: versionMatch[2],
        sections: [],
      };
      currentSection = null;
      continue;
    }

    if (!current) continue;

    const sectionMatch = line.match(/^### (.+)$/);
    if (sectionMatch) {
      currentSection = { heading: sectionMatch[1], items: [] };
      current.sections.push(currentSection);
      continue;
    }

    const itemMatch = line.match(/^- (.+)$/);
    if (itemMatch) {
      if (currentSection) {
        currentSection.items.push(itemMatch[1]);
      } else {
        // Items without a ### heading (e.g. 1.0.x initial release)
        if (!current.sections.length) {
          currentSection = { heading: "", items: [] };
          current.sections.push(currentSection);
        }
        current.sections[current.sections.length - 1].items.push(
          itemMatch[1]
        );
      }
      continue;
    }

    // Non-empty lines that aren't headings or items (intro text)
    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      current.intro = trimmed;
    }
  }

  if (current) versions.push(current);
  return versions;
}

function InlineCode({ text }: { text: string }) {
  const parts = text.split(/(`[^`]+`)/g);
  return (
    <>
      {parts.map((part, i) =>
        part.startsWith("`") && part.endsWith("`") ? (
          <code key={i}>{part.slice(1, -1)}</code>
        ) : (
          <span key={i}>{part}</span>
        )
      )}
    </>
  );
}

export default function ChangelogPage() {
  const changelogPath = path.join(process.cwd(), "..", "CHANGELOG.md");
  const markdown = fs.readFileSync(changelogPath, "utf-8");
  const versions = parseChangelog(markdown);

  return (
    <>
      <h1>Changelog</h1>
      <p>All notable changes to cmux are documented here.</p>

      {versions.map((v) => (
        <div key={v.version} className="mb-8">
          <h2>
            {v.version}{" "}
            <span className="text-muted font-normal text-[14px]">
              — {v.date}
            </span>
          </h2>
          {v.intro && <p>{v.intro}</p>}
          {v.sections.map((section, i) => (
            <div key={i}>
              {section.heading && <h3>{section.heading}</h3>}
              <ul>
                {section.items.map((item, j) => (
                  <li key={j}>
                    <InlineCode text={item} />
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      ))}
    </>
  );
}
