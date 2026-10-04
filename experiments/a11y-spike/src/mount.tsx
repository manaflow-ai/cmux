import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App, Providers } from "virtual:spike-lib";
import "./spike.css";

const rtl = new URLSearchParams(location.search).has("rtl");
if (rtl) document.documentElement.dir = "rtl";
createRoot(document.getElementById("root")!).render(<StrictMode><Providers><App /></Providers></StrictMode>);
