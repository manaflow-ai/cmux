import { type ReactNode } from "react";
import { foreignFileIds, pathName, textLinks } from "./paths";
import { bareFileNames } from "./replyFolders";
import { githubRefLabel } from "./linkChipsModel";
import { ForeignFileRef, PathChip, UrlChip, SiblingFileChip } from "./LinkChips";
import { CmuxLinkChip } from "./CmuxLinkChip";
import { cmuxLinkTarget } from "../conversation/cmuxLinks";
import { deeplinks } from "../composer/deeplinks";
import { SoftBroken } from "../conversation/softBreaks";

/// Plain reply text with its paths and URLs as chips (D4); `key` prefixes the chips' keys. A cmux
/// app link (`cmux://workspace/ws_…`, `cmux-nightly://agent/…`) draws as what it names, else as a
/// link the host opens in the app (CmuxLinkChip.tsx), never as a path.
export function linkedText(text: string, key: string): ReactNode[] {
  const app = text.includes("://") ? deeplinks(text).filter((link) => !link.href.startsWith("https:")) : [];
  if (app.length) {
    const out: ReactNode[] = [];
    let at = 0;
    app.forEach((link, index) => {
      if (link.start > at) out.push(...webLinkedText(text.slice(at, link.start), `${key}-${index}-app-before`));
      out.push(
        <CmuxLinkChip
          key={`${key}-${index}-app`}
          href={link.href}
          fallback={
            <a className="cv-link is-app" href={link.href}>
              <SoftBroken text={link.href} />
            </a>
          }
        />,
      );
      at = link.end;
    });
    if (at < text.length) out.push(...webLinkedText(text.slice(at), `${key}-app-after`));
    return out;
  }
  return webLinkedText(text, key);
}

function webLinkedText(text: string, key: string): ReactNode[] {
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
      ) : link.value.includes("/deeplink/") && cmuxLinkTarget(link.value) ? (
        // cmux.com's agent link: the chat it names, once the page knows it.
        <CmuxLinkChip
          key={`${key}-${index}`}
          href={link.value}
          fallback={<UrlChip href={link.value}>{link.value}</UrlChip>}
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

/// `text` with each foreign file id (`foreignFileIds`) as its `ForeignFileRef`, the rest drawn by
/// `rest`. `ids`: the text's ids when the caller found them already.
export function withForeignFiles(
  text: string,
  key: string,
  rest: (piece: string, key: string) => ReactNode[],
  ids = foreignFileIds(text),
): ReactNode[] {
  if (!ids.length) return rest(text, key);
  const out: ReactNode[] = [];
  let at = 0;
  ids.forEach((id, index) => {
    if (id.start > at) out.push(...rest(text.slice(at, id.start), `${key}-${index}-text`));
    out.push(<ForeignFileRef key={`${key}-${index}-foreign`} id={id.value} />);
    at = id.end;
  });
  if (at < text.length) out.push(...rest(text.slice(at), `${key}-foreign-tail`));
  return out;
}

/// Text between a reply's paths: each bare file name may be a file in a folder the reply names.
function namedText(text: string, key: string): ReactNode[] {
  return withForeignFiles(text, key, siblingText);
}

function siblingText(text: string, key: string): ReactNode[] {
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
