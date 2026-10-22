// Browser harness for test/path-picker-long.test.ts: the path picker over the gallery's fixture
// folders (viewer-empty.path-picker, variant `virtualized`: cmux holds 300 folders, so the list
// virtualizes), with the picker's styles.
import "../../src/viewer-empty/styles.css";
import "../../src/viewer-empty/PathPicker.gallery.css";
import { createRoot } from "react-dom/client";
import entry from "../../src/viewer-empty/PathPicker.gallery";

const Gallery = await entry.load();
createRoot(document.getElementById("root")!).render(<Gallery {...entry.variants.virtualized!.props!} />);
