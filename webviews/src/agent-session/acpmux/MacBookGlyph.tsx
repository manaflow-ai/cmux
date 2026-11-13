import { useId } from "react";
import macBook from "./icons/macbook-regular@2x.png";

// The selected macbook.gen2 SF Symbol, regular weight at 16 pt, exported at 2x.
export function MacBookGlyph() {
  const maskId = `macbook-${useId().replace(/[^\w-]/g, "")}`;
  return (
    <>
      <mask id={maskId} x={0} y={0} width={16} height={16} maskUnits="userSpaceOnUse">
        <image href={macBook} width={16} height={16} />
      </mask>
      <rect width={16} height={16} fill="currentColor" stroke="none" mask={`url(#${maskId})`} />
    </>
  );
}
