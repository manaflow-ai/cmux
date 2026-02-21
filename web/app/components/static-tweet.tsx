import { PlatformIcon } from "../testimonials";

export function StaticTweet({
  name,
  handle,
  avatar,
  text,
  url,
  date,
}: {
  name: string;
  handle: string;
  avatar?: string;
  text: string;
  url: string;
  date: string;
}) {
  const initials = name
    .split(/[\s_-]+/)
    .map((w) => w[0])
    .join("")
    .toUpperCase()
    .slice(0, 2);

  return (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      className="group block rounded-xl border border-border p-5 hover:bg-code-bg transition-colors my-6"
    >
      <div className="flex items-center gap-3 mb-3">
        {avatar ? (
          <img
            src={avatar}
            alt={name}
            width={40}
            height={40}
            className="rounded-full shrink-0"
          />
        ) : (
          <div className="w-10 h-10 rounded-full bg-code-bg border border-border flex items-center justify-center text-xs font-medium text-muted shrink-0">
            {initials}
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="font-medium text-sm truncate">{name}</div>
          <div className="text-xs text-muted truncate">{handle}</div>
        </div>
        <PlatformIcon platform="x" />
      </div>
      <p className="text-[15px] leading-relaxed text-muted group-hover:text-foreground transition-colors whitespace-pre-line">
        {text}
      </p>
      <div className="text-xs text-muted mt-3">{date}</div>
    </a>
  );
}
