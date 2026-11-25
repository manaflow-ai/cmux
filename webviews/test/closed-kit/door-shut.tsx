/** @jsxImportSource ../../src/kit/closed */
// The closed kit's negative fixture (RFD 0040): a hand-set corner and a raw element under
// `@ts-expect-error`. If the closed runtime (src/kit/closed/jsx-runtime.ts) ever lets either compile,
// the directive is unused and `bun run check:closed-kit` fails. The first element is the control: a kit
// piece with kit props still compiles. Never rendered or imported; it exists to be type-checked.
import { Glass } from "../../src/kit";

export function DoorShut() {
  return (
    <>
      <Glass level="chip">kit pieces compile</Glass>
      {/* @ts-expect-error a hand-set value does not compile in a closed directory */}
      <Glass style={{ borderRadius: 7 }}>hand-set corner</Glass>
      {/* @ts-expect-error a raw element does not compile in a closed directory */}
      <button type="button">raw element</button>
    </>
  );
}
