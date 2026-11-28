"use client";

import Image, { type ImageProps } from "next/image";
import { useState } from "react";

export function FadeImage(props: ImageProps) {
  const [loaded, setLoaded] = useState(false);

  return (
    <Image
      {...props}
      placeholder={undefined}
      className={`${props.className ?? ""} transition-opacity duration-700 ${loaded ? "opacity-100" : "opacity-0"}`}
      onLoad={() => setLoaded(true)}
    />
  );
}
