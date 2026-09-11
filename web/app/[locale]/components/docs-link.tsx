import type { ComponentProps } from "react";
import { Link } from "@/i18n/navigation";
import { docsChannel, docsChannelUrl } from "@/app/lib/docs-channel";

export function DocsLink(props: ComponentProps<typeof Link>) {
  const href = typeof props.href === "string"
    ? docsChannelUrl(docsChannel(), props.href)
    : props.href;
  return <Link {...props} href={href} />;
}
