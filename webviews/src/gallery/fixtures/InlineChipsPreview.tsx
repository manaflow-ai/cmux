// l10n-allow-file: public gallery sample prose, not shipped UI.
import { PathChip, ElsewhereChip, UrlChip } from "../../agent-session/acpmux/chips/LinkChips";

type InlineChipVariant = "before" | "minimal" | "accent" | "hairline";

export function InlineChipsPreview({ variant }: { variant: InlineChipVariant }) {
  return (
    <div className={`cv-md inline-chip-preview is-${variant}`}>
      <p>
        Update <PathChip path="/example/project/cmux.json" /> and the <PathChip path="/example/project/src/" /> folder,
        then read <UrlChip href="https://example.test/guide">the guide</UrlChip>.
      </p>
      <p>
        Review <UrlChip href="https://github.com/example/project/pull/42">example/project#42</UrlChip> before calling{" "}
        <PathChip path="/example/project/src/config.ts:42" label={<code className="cv-code">parseConfig</code>} />.
      </p>
      <p>
        Outside the project: <PathChip path="/tmp/example/notes.md" />. On another machine:{" "}
        <ElsewhereChip path="/example/remote/cmux.json" host="example-host" />.
      </p>
      <p>
        A long path wraps in narrow panes:{" "}
        <PathChip
          path="/example/project/src/configuration/resolve-project-settings.ts"
          label="src/configuration/resolve-project-settings.ts"
        />
        . The sentence continues here.
      </p>
    </div>
  );
}
