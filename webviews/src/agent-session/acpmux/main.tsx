import { mountAcpmux } from "./mountModel";
// The Codex app look (look/README.md): imported after the pane, so its sheet comes after every
// sheet the pane's components import and restyles them.
import "./look/codexLook.css";

mountAcpmux();
