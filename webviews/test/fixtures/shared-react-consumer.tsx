// A bundle built against the shared React (test/shared-react.test.ts): an ES import, a CommonJS
// require (react-dom/server's own, and this file's) and the JSX runtime must all reach one React,
// or the hooks below throw.
import { useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";

declare const require: (id: string) => typeof import("react");
const required = require("react");

function Counter() {
  const [count] = useState(1);
  const store = required.useSyncExternalStore(
    () => () => {},
    () => 7,
    () => 7,
  );
  return <p>{`count ${count} store ${store}`}</p>;
}

export function render(): string {
  return renderToStaticMarkup(<Counter />);
}
