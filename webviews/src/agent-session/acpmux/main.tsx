import { mountAcpmux } from "./mountModel";
import { acpmuxPerf } from "./perf";

// After every module of the bundle evaluated (imports run first): the span from pane.js's fetch to here is its
// parse, compile and evaluation (`bootMarks`, the relaunch's `agent_page.modulesEvaluated`).
acpmuxPerf.markLaunch("modulesEvaluated");
mountAcpmux();
acpmuxPerf.markLaunch("mountCalled");
