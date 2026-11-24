import { useT } from "../i18n";
import { safeHref } from "../model";
import { ForeignFileRef } from "../chips/LinkChips";
import { foreignFileId } from "../chips/paths";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { ImageIcon } from "./icons";
import { DATA_REF, INLINE_IMAGE, MAX_DATA_URL_LENGTH, OVERSIZED_DATA_URL } from "./markdownModel";
import { linkLabel, renderInline, type InlineOptions } from "./inlineMarkdown";

/// `![alt](src)`: a data URL image draws inline, and a click opens it in the image viewer; a web
/// image the pane cannot load draws as a link to it, named by its alt text or file name.
export function InlineImage({ source, opts }: { source: string; opts: InlineOptions }) {
  const [, alt = "", written = ""] = source.match(/^!\[([^\]]*)\]\((.+)\)$/) ?? [];
  const src = written.startsWith(DATA_REF) ? (opts.dataRefs?.[Number(written.slice(DATA_REF.length))] ?? "") : written;
  if (opts.overBudget?.has(src)) return <OversizedImage alt={alt} opts={opts} />;
  if (src === OVERSIZED_DATA_URL || (INLINE_IMAGE.test(src) && src.length > MAX_DATA_URL_LENGTH))
    return <OversizedImage alt={alt} opts={opts} />;
  if (INLINE_IMAGE.test(src)) return <OpenableImage src={src} alt={alt} thumb />;
  // An image only its provider opens (`sediment://…`) is named as that, never a broken image.
  const foreign = foreignFileId(src);
  if (foreign) return <ForeignFileRef id={foreign} />;
  const name = alt || src.split(/[?#]/)[0]!.split("/").filter(Boolean).at(-1) || src;
  const labelOpts = {
    ...opts,
    githubRepository: undefined,
    linkGithubReferences: false,
    started: undefined,
    claims: undefined,
  };
  const href = safeHref(src);
  const fallback = !href ? (
    <span className="cv-link is-image">
      <ImageIcon size={16} className="cv-link__icon" />
      {linkLabel(name, labelOpts)}
    </span>
  ) : (
    <a className="cv-link is-image" href={href} rel="noreferrer">
      <ImageIcon size={16} className="cv-link__icon" />
      {linkLabel(name, labelOpts)}
    </a>
  );
  // A file inside the session's folders, or a web image, loads through the host (D5).
  return <ReplyImage src={src} alt={alt} fallback={fallback} thumb />;
}

/// A data URL image over MAX_DATA_URL_LENGTH: its alt text (or "Image too large to show") with the
/// image mark, never the URL itself.
function OversizedImage({ alt, opts }: { alt: string; opts: InlineOptions }) {
  const t = useT();
  return (
    <span
      className="cv-link is-image"
      /* tooltip-allow: why the image does not show */ title={t("markdown.imageTooLarge")}
    >
      <ImageIcon size={16} className="cv-link__icon" />
      {alt
        ? renderInline(alt, { ...opts, githubRepository: undefined, linkGithubReferences: false, claims: undefined })
        : t("markdown.imageTooLarge")}
    </span>
  );
}
