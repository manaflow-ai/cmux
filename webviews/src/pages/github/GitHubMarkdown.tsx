// A pull request's body and its comments. When the host sent GitHub's own rendering (`bodyHTML`),
// githubHTML.tsx draws that from its allowlist. Otherwise, or where it cannot parse, this renders
// the Markdown (GitHub flavored: tables, task lists, strikethrough). Like the diff viewer's Rich
// preview (MarkdownPreview.tsx), it draws marked's tokens as React elements and never sets HTML, so
// nothing in a body can run or restyle the page: raw HTML shows as its text (an HTML comment, a
// pull request template's hint, shows nothing), an image shows its alt text as a link to it, and
// a link opens through the host only when it is https, on the person's click.
import { lexer, type Token, type Tokens } from "marked";
import { Fragment, useMemo, type ReactNode } from "react";
import { githubHTML } from "./githubHTML";
import { Link, type Open } from "./githubLink";

export { openableLink } from "./githubLink";

const HTML_COMMENT = /^\s*<!--[\s\S]*?-->\s*$/;

function inline(tokens: readonly Token[] | undefined, open: Open): ReactNode {
  return (tokens ?? []).map((token, index) => <Fragment key={index}>{inlineToken(token, open)}</Fragment>);
}

function inlineToken(token: Token, open: Open): ReactNode {
  switch (token.type) {
    case "strong":
      return <strong>{inline((token as Tokens.Strong).tokens, open)}</strong>;
    case "em":
      return <em>{inline((token as Tokens.Em).tokens, open)}</em>;
    case "del":
      return <del>{inline((token as Tokens.Del).tokens, open)}</del>;
    case "codespan":
      return <code>{(token as Tokens.Codespan).text}</code>;
    case "br":
      return <br />;
    case "link": {
      const link = token as Tokens.Link;
      return (
        <Link href={link.href} open={open}>
          {inline(link.tokens, open)}
        </Link>
      );
    }
    case "image": {
      const image = token as Tokens.Image;
      return (
        <Link href={image.href} open={open}>
          {image.text || image.href}
        </Link>
      );
    }
    case "text": {
      const text = token as Tokens.Text;
      return text.tokens ? inline(text.tokens, open) : text.text;
    }
    case "escape":
      return (token as Tokens.Escape).text;
    case "html": {
      const html = (token as Tokens.HTML).text;
      return HTML_COMMENT.test(html) ? null : html;
    }
    default:
      return "raw" in token ? String(token.raw) : null;
  }
}

function block(token: Token, index: number, open: Open): ReactNode {
  switch (token.type) {
    case "space":
      return null;
    case "heading": {
      const heading = token as Tokens.Heading;
      // A body's headings sit under the page's own: h3 and below.
      const Tag = `h${Math.min(6, Math.max(3, heading.depth + 2))}` as "h3";
      return <Tag key={index}>{inline(heading.tokens, open)}</Tag>;
    }
    case "paragraph":
      return <p key={index}>{inline((token as Tokens.Paragraph).tokens, open)}</p>;
    case "text": {
      const text = token as Tokens.Text;
      return <p key={index}>{text.tokens ? inline(text.tokens, open) : text.text}</p>;
    }
    case "blockquote":
      return <blockquote key={index}>{blocks((token as Tokens.Blockquote).tokens, open)}</blockquote>;
    case "code":
      return (
        <pre key={index}>
          <code>{(token as Tokens.Code).text}</code>
        </pre>
      );
    case "hr":
      return <hr key={index} />;
    case "list": {
      const list = token as Tokens.List;
      const items = list.items.map((item, at) => (
        <li key={at} data-task={item.task ? (item.checked ? "done" : "open") : undefined}>
          {item.task ? <span className="gh-md-task" aria-hidden="true" /> : null}
          {blocks(
            item.tokens.filter((child) => child.type !== "checkbox"),
            open,
          )}
        </li>
      ));
      return list.ordered ? (
        <ol key={index} start={typeof list.start === "number" ? list.start : undefined}>
          {items}
        </ol>
      ) : (
        <ul key={index}>{items}</ul>
      );
    }
    case "table": {
      const table = token as Tokens.Table;
      const align = (at: number) => table.align[at] ?? undefined;
      return (
        <div key={index} className="gh-md-table">
          <table>
            <thead>
              <tr>
                {table.header.map((cell, at) => (
                  <th key={at} style={{ textAlign: align(at) }}>
                    {inline(cell.tokens, open)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((row, rowAt) => (
                <tr key={rowAt}>
                  {row.map((cell, at) => (
                    <td key={at} style={{ textAlign: align(at) }}>
                      {inline(cell.tokens, open)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    }
    case "html": {
      const html = (token as Tokens.HTML).text;
      return HTML_COMMENT.test(html) ? null : (
        <p key={index} className="gh-md-html">
          {html}
        </p>
      );
    }
    default:
      return "raw" in token ? <p key={index}>{String(token.raw)}</p> : null;
  }
}

function blocks(tokens: readonly Token[], open: Open): ReactNode {
  return tokens.map((token, index) => block(token, index, open));
}

/** GitHub's own rendering of the body when the host sent it (githubHTML.tsx), else `source`
 * rendered here; links open through `open`. */
export function GitHubMarkdown({ source, html, open }: { source: string; html?: string; open: Open }) {
  const drawn = useMemo(() => (html ? githubHTML(html, open) : null), [html, open]);
  const tokens = useMemo(() => (drawn ? [] : lexer(source, { gfm: true })), [drawn, source]);
  return <div className="gh-md">{drawn ?? blocks(tokens, open)}</div>;
}
