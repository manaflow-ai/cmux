import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { router } from "./Shell";
import "./shell.css";

createRoot(document.getElementById("gallery")!).render(<RouterProvider router={router as never} />);
