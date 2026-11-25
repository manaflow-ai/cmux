// The kit's closed JSX runtime (RFD 0040, the closed kit): in a closed directory, raw values do not
// compile. A file opts in with `/** @jsxImportSource <relative path to src/kit/closed> */` on its first
// line, and tsconfig.closed.json lists its directory. At run time it is React's own runtime, re-exported,
// so closing a directory changes no pixel; only the types differ:
//   - no intrinsic elements: `<div>`, `<button>`, `<span>` do not compile. A closed file composes kit
//     pieces (kit/index.ts), and a piece it lacks is added to the kit, not hand-rolled;
//   - no `style` and no `className` on any component: the two doors through which a hand-set value
//     (a corner, a gap, a colour) reaches a rendered element. The look comes from the kit's props.
// test/closed-kit/door-shut.tsx holds both under `@ts-expect-error`, so the type check fails the
// moment either door reopens.
import type * as React from "react";

export { Fragment, jsx, jsxs } from "react/jsx-runtime";

/** The attributes no component takes in a closed directory. */
type OpenDoors = "style" | "className";

/** Props less the open doors, per member of a union (a discriminated props union stays one). */
type Closed<P> = P extends unknown ? Omit<P, OpenDoors> : never;

export declare namespace JSX {
  /** Only components; a string tag (an intrinsic element) is not a JSX element type here. */
  type ElementType = React.JSXElementConstructor<any>;
  interface Element extends React.JSX.Element {}
  interface ElementClass extends React.JSX.ElementClass {}
  interface ElementAttributesProperty extends React.JSX.ElementAttributesProperty {}
  interface ElementChildrenAttribute extends React.JSX.ElementChildrenAttribute {}
  type LibraryManagedAttributes<C, P> = Closed<React.JSX.LibraryManagedAttributes<C, P>>;
  interface IntrinsicAttributes extends React.JSX.IntrinsicAttributes {}
  interface IntrinsicClassAttributes<T> extends React.JSX.IntrinsicClassAttributes<T> {}
  /** Empty: no `<div>`, no `<button>`. */
  interface IntrinsicElements {}
}
