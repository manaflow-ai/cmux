// The verb column of tool rows, as the Codex app lines its rows up: in a turn's tool rows ("Ran git
// status", "Read App.tsx", "Edited ToolRow.tsx +4 -1") each row's verb sits in one column as wide as
// the widest verb among them, so every subject starts at the same x (Leo 2026-10-29: "having stuff
// aligned is nice").
//
// `ToolVerbColumn` counts the verbs its rows draw; each row registers its verb once, when it mounts
// or its verb changes, never per streamed token. The column's element carries them as one CSS string
// (`--cv-tool-verbs`, a verb a line) that each verb's hidden `::after` lays out under it
// (conversation.css `.cv-tool__verb`), so a verb's box is as wide as the widest without measuring
// anything. Only the column's own element draws again (its rows are the same elements, so React
// skips them), and only when a verb first appears in it or its last row goes.
import {
  createContext,
  useContext,
  useLayoutEffect,
  useMemo,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { useT, type Translate } from "../i18n";

type VerbColumn = { add: (verb: string) => () => void };

const VerbColumnContext = createContext<VerbColumn | undefined>(undefined);

/// A label's verb and the rest, split at its first space ("Ran git status": "Ran", "git status").
/// Undefined when it does not start with a word and a space.
export function splitToolLabel(text: string): { verb: string; subject: string } | undefined {
  // One plain space only: the split draws one, so any other gap would change the words.
  const match = /^(\p{L}+) (\S[\s\S]*)$/u.exec(text);
  return match ? { verb: match[1]!, subject: match[2]! } : undefined;
}

/// Whether the reader's language puts the verb first ("Ran {command}", not "{command} を実行しました"
/// or "{command} ausgeführt"): only then do the rows' first words make a column.
export function verbLeads(t: Translate): boolean {
  return /^\p{L}+ \uE000$/u.test(t("tools.ranCommand", { command: "\uE000" }));
}

/// The verb of a translated line's text before its subject ("Ran " of "Ran {command}"), when it is
/// one word and a space.
export function leadingVerb(before: string): string | undefined {
  return /^(\p{L}+) $/u.exec(before)?.[1];
}

/// Verbs as one CSS string, a verb a line (`\A`), quotes and backslashes escaped.
export function verbsCss(verbs: readonly string[]): string {
  return `"${verbs.map((verb) => verb.replace(/[\\"]/g, (c) => `\\${c}`)).join("\\A ")}"`;
}

/// The element whose tool rows share one verb column (the gallery's ToolRowColumn.gallery.tsx); the
/// transcript draws none (Leo, 2026-10-31: "why are these indented for no reason").
export function ToolVerbColumn({ className, children }: { className: string; children: ReactNode }) {
  const t = useT();
  const leads = verbLeads(t);
  const [verbs, setVerbs] = useState<readonly string[]>([]);
  const column = useMemo<VerbColumn>(() => {
    const counts = new Map<string, number>();
    const publish = () => setVerbs([...counts.keys()]);
    return {
      add(verb) {
        const count = counts.get(verb) ?? 0;
        counts.set(verb, count + 1);
        if (count === 0) publish();
        return () => {
          const left = (counts.get(verb) ?? 1) - 1;
          if (left > 0) counts.set(verb, left);
          else {
            counts.delete(verb);
            publish();
          }
        };
      },
    };
  }, []);
  const style = useMemo(
    () => (verbs.length > 0 ? ({ "--cv-tool-verbs": verbsCss(verbs) } as CSSProperties) : undefined),
    [verbs],
  );
  return (
    <VerbColumnContext.Provider value={leads ? column : undefined}>
      <div className={className} style={style} data-tool-verbs={verbs.length || undefined}>
        {children}
      </div>
    </VerbColumnContext.Provider>
  );
}

/// A row's verb in the column. Registered before paint, so a row never draws out of line first.
function ToolVerb({
  column,
  skip,
  tight,
  children,
}: {
  column: VerbColumn;
  skip?: boolean;
  tight?: boolean;
  children: string;
}) {
  useLayoutEffect(() => (tight ? undefined : column.add(children)), [column, children, tight]);
  return (
    <span className={tight ? "cv-tool__verb is-tight" : "cv-tool__verb"} data-find-skip={skip || undefined}>
      {children}
    </span>
  );
}

/// A tool row's label with its verb in the column: `verb` and `subject` when the caller knows them
/// (the parts of a translated "Ran {command}"), otherwise `text` split at its first space. A label
/// with no verb to split off draws as `children` (or `text`) do, as does any label outside a column
/// or in a language whose verb does not lead, and a `whole` one (an MCP call's plain name, "Hub ·
/// read chat", starts with its server, not a verb). `skip`: Find in Chat skips the verb and the space
/// after it, as it skipped "Ran " before the column. `tight`: a count summary ("Ran 2 commands")
/// keeps its verb out of the column's width, so one plain space parts the verb and the count.
export function ToolLabel({
  text,
  verb,
  subject,
  skip,
  whole,
  tight,
  children,
}: {
  text?: string;
  verb?: string;
  subject?: ReactNode;
  skip?: boolean;
  whole?: boolean;
  tight?: boolean;
  children?: ReactNode;
}) {
  const column = useContext(VerbColumnContext);
  const split = column && !whole && verb === undefined && text !== undefined ? splitToolLabel(text) : undefined;
  const head = verb ?? split?.verb;
  if (!column || !head) return <>{children ?? text}</>;
  // One run for Find's highlights (chatFind.ts findRuns): a match may span the verb and the subject.
  return (
    <span className="cv-tool-label" data-find-join="">
      <ToolVerb column={column} skip={skip} tight={tight}>
        {head}
      </ToolVerb>
      <span className="cv-tool-label__space" data-find-skip={skip || undefined}>
        {" "}
      </span>
      <span className="cv-tool-label__subject">{subject ?? split?.subject}</span>
    </span>
  );
}
