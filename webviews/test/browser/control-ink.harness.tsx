import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "../../src/ui/Button";
import { Row } from "../../src/kit/Row";

function Controls() {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState(false);
  return (
    <>
      <Button aria-expanded={open} data-popup-open={open ? "" : undefined} onClick={() => setOpen(!open)}>
        Options
      </Button>
      <ul>
        <Row title="Session" selected={selected} onSelect={() => setSelected(!selected)} />
      </ul>
    </>
  );
}
createRoot(document.querySelector("main")!).render(<Controls />);
