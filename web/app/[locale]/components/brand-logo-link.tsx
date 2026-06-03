"use client";

import type { ReactNode } from "react";
import { Link, useRouter } from "../../../i18n/navigation";

export function BrandLogoLink({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  const router = useRouter();

  return (
    <Link
      href="/"
      className={className}
      onContextMenu={(event) => {
        event.preventDefault();
        router.push("/assets");
      }}
    >
      {children}
    </Link>
  );
}
