"use client";

import type { ComponentProps } from "react";
import { Link } from "@/i18n/navigation";
import { docsChannelUrl } from "@/app/lib/docs-channel";
import { useDocsChannel } from "./docs-channel-context";

export function DocsLink(props: ComponentProps<typeof Link>) {
  const channel = useDocsChannel();
  const href = typeof props.href === "string"
    ? docsChannelUrl(channel, props.href)
    : props.href;
  return <Link {...props} href={href} />;
}
