// The Rich preview sheet's rendered Markdown. It draws marked's tokens as React elements and
// never sets HTML: raw HTML in the file shows as its text, a link is styled text (the sheet does
// not navigate the page), and an image shows its alt text (a preview fetches nothing).
import { lexer, type Token, type Tokens } from "marked";
import { Fragment, useMemo, type ReactNode } from "react";

function inline(tokens: readonly Token[] | undefined): ReactNode {
  return (tokens ?? []).map((token, index) => <Fragment key={index}>{inlineToken(token)}</Fragment>);
}

function inlineToken(token: Token): ReactNode {
  switch (token.type) {
    case "strong":
      return <strong>{inline((token as Tokens.Strong).tokens)}</strong>;
    case "em":
      return <em>{inline((token as Tokens.Em).tokens)}</em>;
    case "del":
      return <del>{inline((token as Tokens.Del).tokens)}</del>;
    case "codespan":
      return <code>{(token as Tokens.Codespan).text}</code>;
    case "br":
      return <br />;
    case "link":
      return <span className="md-link">{inline((token as Tokens.Link).tokens)}</span>;
    case "image":
      return <span className="md-image">{(token as Tokens.Image).text || (token as Tokens.Image).href}</span>;
    case "text": {
      const text = token as Tokens.Text;
      return text.tokens ? inline(text.tokens) : text.text;
    }
    case "escape":
      return (token as Tokens.Escape).text;
    case "html":
      return (token as Tokens.HTML).text;
    default:
      return "raw" in token ? String(token.raw) : null;
  }
}

function block(token: Token, index: number): ReactNode {
  switch (token.type) {
    case "space":
      return null;
    case "heading": {
      const heading = token as Tokens.Heading;
      const Tag = `h${Math.min(6, Math.max(1, heading.depth))}` as "h1";
      return <Tag key={index}>{inline(heading.tokens)}</Tag>;
    }
    case "paragraph":
      return <p key={index}>{inline((token as Tokens.Paragraph).tokens)}</p>;
    case "text": {
      const text = token as Tokens.Text;
      return <p key={index}>{text.tokens ? inline(text.tokens) : text.text}</p>;
    }
    case "blockquote":
      return <blockquote key={index}>{blocks((token as Tokens.Blockquote).tokens)}</blockquote>;
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
          {item.task ? <span className="md-task" aria-hidden="true" /> : null}
          {blocks(item.tokens.filter((child) => child.type !== "checkbox"))}
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
        <table key={index}>
          <thead>
            <tr>
              {table.header.map((cell, at) => (
                <th key={at} style={{ textAlign: align(at) }}>
                  {inline(cell.tokens)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {table.rows.map((row, rowAt) => (
              <tr key={rowAt}>
                {row.map((cell, at) => (
                  <td key={at} style={{ textAlign: align(at) }}>
                    {inline(cell.tokens)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      );
    }
    case "html":
      return (
        <pre key={index} className="md-html">
          {(token as Tokens.HTML).text}
        </pre>
      );
    default:
      return "raw" in token ? <p key={index}>{String(token.raw)}</p> : null;
  }
}

function blocks(tokens: readonly Token[]): ReactNode {
  return tokens.map(block);
}

/** Markdown `source`, rendered (GitHub flavored: tables, task lists, strikethrough). */
export function MarkdownPreview({ source }: { source: string }) {
  const tokens = useMemo(() => lexer(source, { gfm: true }), [source]);
  return <div className="rich-preview-markdown">{blocks(tokens)}</div>;
}
