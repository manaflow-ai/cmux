import { type ReactNode } from "react";
import { usePaneLanguage } from "./i18n";
import { FileDoc, Folder } from "./conversation/icons";
import type { AttachmentSource } from "./attachments";
import { SourceBadge } from "./composer/SourceBadge";
import { useSourceLabel, withSourceLabel } from "./composer/sourceBadgeModel";
import { fileSizeLabel } from "./fileAttachmentModel";

export type FileAttachmentInfo = {
  name: string;
  size?: number;
  mimeType?: string;
  path?: string;
  /** The app it came from: its icon rides the file glyph's top-right corner (composer/SourceBadge.tsx). */
  source?: AttachmentSource;
};

/** The same quiet file body in a draft and a sent message. Images keep their own thumbnails. */
export function FileAttachment({ file, remove }: { file: FileAttachmentInfo; remove?: ReactNode }) {
  const language = usePaneLanguage();
  const folder = file.name.endsWith("/");
  const type = file.name.split(".").at(-1)?.toLowerCase() ?? "";
  const key = ["pem", "key", "p12", "pfx", "crt", "cer"].includes(type);
  const archive = ["zip", "gz", "tgz", "tar", "7z"].includes(type);
  // Flex clips only the head: the final stem and complete extension stay visible at narrow widths.
  const chars = Array.from(file.name);
  const tailLength = Math.max(8, type.length + 1);
  const tail = chars.length > tailLength + 8 ? chars.slice(-tailLength).join("") : "";
  const head = tail ? chars.slice(0, -tailLength).join("") : file.name;
  const size = folder ? undefined : fileSizeLabel(file.size, language);
  const from = useSourceLabel(file.source);
  return (
    <span
      className={`acpmux-file-chip${remove ? " acpmux-file-chip--removable" : ""}`}
      data-file-type={folder ? "folder" : type}
      /* tooltip-allow: the filename may be middle-truncated; the full path is secondary detail */
      title={withSourceLabel(file.path ?? file.name, from)}
    >
      {folder ? (
        <Folder size={16} />
      ) : key || archive ? (
        <svg
          width="16"
          height="16"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.1"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          {key ? (
            <>
              <circle cx="5.5" cy="5.5" r="3" />
              <path d="m7.7 7.7 5.8 5.8m-2-2 1.5-1.5m-3.5-.5L11 8.5" />
            </>
          ) : (
            <>
              <path d="M4.25 2.25h5l3 3v8.5h-8ZM9.25 2.25v3h3" />
              <path d="M7 3v1m1 0v1M7 5v1m1 0v1M7 7v1m1 0v1M7 10h2v2H7Z" />
            </>
          )}
        </svg>
      ) : (
        <FileDoc size={16} />
      )}
      <span className="acpmux-file-chip__name acpmux-attachment-link-name" dir="ltr">
        <span className="acpmux-file-chip__head">{head}</span>
        {tail && <span className="acpmux-file-chip__tail">{tail}</span>}
      </span>
      {size && <span className="acpmux-file-chip__size">{size}</span>}
      <SourceBadge source={file.source} />
      {remove}
    </span>
  );
}
