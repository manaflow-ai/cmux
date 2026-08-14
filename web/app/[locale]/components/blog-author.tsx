import Image from "next/image";
import {
  lawrenceChen,
  type BlogAuthor,
} from "./blog-authors";

export function BlogPostMeta({
  date,
  dateTime,
  author = lawrenceChen,
  compact = false,
}: {
  date: string;
  dateTime: string;
  author?: BlogAuthor;
  compact?: boolean;
}) {
  const avatarSize = compact ? 22 : 28;

  return (
    <div
      className="not-prose mt-2 flex flex-wrap items-center gap-x-2 text-sm text-muted"
    >
      <a
        href={author.url}
        target="_blank"
        rel="noreferrer"
        className="group inline-flex items-center gap-2 text-muted transition-colors hover:text-foreground"
      >
        <Image
          src={author.avatar}
          alt=""
          width={avatarSize}
          height={avatarSize}
          className="rounded-full"
        />
        <span className="font-medium text-foreground">{author.name}</span>
        <span className="transition-colors group-hover:text-foreground">
          {author.handle}
        </span>
      </a>
      <span aria-hidden="true">·</span>
      <time dateTime={dateTime}>{date}</time>
    </div>
  );
}
