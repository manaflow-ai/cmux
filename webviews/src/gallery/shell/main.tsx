import { createRoot } from "react-dom/client";
import { Shell } from "./Shell";
import "./shell.css";

createRoot(document.getElementById("gallery")!).render(<Shell />);
