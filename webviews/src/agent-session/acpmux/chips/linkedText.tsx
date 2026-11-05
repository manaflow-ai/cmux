import { type ReactNode } from "react";
import { pathName, textLinks } from "./paths";
import { bareFileNames } from "./replyFolders";
import { githubRefLabel } from "./linkChipsModel";
import { PathChip, UrlChip, SiblingFileChip } from "./LinkChips";

/// Plain reply text with its paths and URLs as chips (D4); `key` prefixes the chips' keys.
export function linkedText(text: string, key: string): ReactNode[] {
  const links = textLinks(text);
  if (!links.length) return namedText(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  links.forEach((link, index) => {
    if (link.start > at) out.push(...namedText(text.slice(at, link.start), `${key}-${index}-names`));
    out.push(
      link.kind === "path" ? (
        <PathChip
          key={`${key}-${index}`}
          path={link.path!}
          written={link.value}
          label={link.line ? `${pathName(link.path!)}:${link.line}` : undefined}
        />
      ) : (
        <UrlChip key={`${key}-${index}`} href={link.value}>
          {githubRefLabel(link.value) ?? link.value}
        </UrlChip>
      ),
    );
    at = link.end;
  });
  if (at < text.length) out.push(...namedText(text.slice(at), `${key}-names`));
  return out;
}

/// Text between a reply's paths: each bare file name may be a file in a folder the reply names.
function namedText(text: string, key: string): ReactNode[] {
  const names = bareFileNames(text);
  if (!names.length) return [text];
  const out: ReactNode[] = [];
  let at = 0;
  names.forEach((name, index) => {
    if (name.start > at) out.push(text.slice(at, name.start));
    out.push(<SiblingFileChip key={`${key}-${index}`} name={name.name} />);
    at = name.end;
  });
  if (at < text.length) out.push(text.slice(at));
  return out;
}
