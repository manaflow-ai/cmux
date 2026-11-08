// Runbooks in the Markdown viewer (runbook.ts): fenced shell blocks become steps, session blocks
// run only their prompt lines, destructive commands and credentials ask first, and the Run all
// prompt lists every step as "Step N of M" with the contract that stops the agent at decisions.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  isRunnableLanguage,
  parseRunbook,
  runAsks,
  runbookPrompt,
  runnableCommand,
  stepRisks,
} from "../src/pages/markdown/runbook";

const fixture = (name: string) => readFileSync(join(import.meta.dir, "fixtures/runbooks", name), "utf8");

describe("runbook steps", () => {
  test("a deploy guide's shell blocks are its steps, in order, with their sections", () => {
    const steps = parseRunbook(fixture("deploy.md"));
    expect(steps.map((step) => step.command)).toEqual([
      "npm ci",
      "npm run build",
      "wrangler login",
      "wrangler deploy --env production",
      "rm -rf dist .wrangler",
    ]);
    expect(steps.map((step) => step.section)).toEqual(["Deploy the web app", "Build", "Log in", "Ship", "Clean up"]);
    expect(steps[1]!.lead).toBe("Build the bundle. It should print `built in`.");
    expect(steps[0]!.line).toBe(5);
  });

  test("decisions, credentials and destructive commands are marked", () => {
    const [install, build, login, ship, clean] = parseRunbook(fixture("deploy.md"));
    expect(install!.risks).toEqual([]);
    expect(build!.risks).toEqual([]);
    expect(login!.risks).toEqual(["credentials"]);
    expect(ship!.risks).toEqual(["destructive", "decision"]);
    expect(clean!.risks).toEqual(["destructive"]);
  });

  test("console blocks run their prompt lines only, with continuations; nested and plain fences are not steps", () => {
    const steps = parseRunbook(fixture("onboarding.md"));
    expect(steps.map((step) => step.command)).toEqual([
      "git clone https://github.com/example/app.git\ncd app && \\\n  ls",
      "export GITHUB_TOKEN=<your-token>",
    ]);
    expect(steps[1]!.risks).toEqual(["credentials"]);
    expect(steps[1]!.section).toBe("Onboarding");
  });

  test("tilde fences and a longer closing fence close a block", () => {
    const steps = parseRunbook("~~~bash\nmake\n~~~~\n\n````sh\nmake test\n```\nstill inside\n````\n");
    expect(steps.map((step) => step.command)).toEqual(["make", "make test\n```\nstill inside"]);
  });

  test("a fence indented four spaces outside a list is an indented code block, not a step", () => {
    const source = "Intro:\n\n    ```bash\n    rm -rf /\n    ```\n\n- Item:\n\n    ```bash\n    make\n    ```\n";
    expect(parseRunbook(source).map((step) => step.command)).toEqual(["make"]);
  });

  test("a block inside an HTML comment is not a step", () => {
    const source = "<!--\n```bash\nrm -rf old\n```\n-->\n\n<!-- one line -->\n\n```bash\nmake\n```\n";
    expect(parseRunbook(source).map((step) => step.command)).toEqual(["make"]);
  });

  test("runnable languages", () => {
    for (const language of ["bash", "sh", "zsh", "shell", "console", 'Bash title="x"', "{bash}"])
      expect(isRunnableLanguage(language)).toBe(true);
    for (const language of ["", "json", "ts", "text", "mermaid", "python"])
      expect(isRunnableLanguage(language)).toBe(false);
    expect(runnableCommand("console", "output only\nno prompt")).toBe("");
    // The continuation prompt is not a redirection: `> world` is the rest of the command.
    expect(runnableCommand("console", "$ echo hello \\\n> world\nhello world\n> not a prompt")).toBe(
      "echo hello \\\nworld",
    );
    expect(runnableCommand("console", "$ cat <<EOF\n> one\n> EOF\none")).toBe("cat <<EOF\none\nEOF");
    // Output is never run: a `> ` line after a finished command, a `# ` line, and an open quote's end.
    expect(runnableCommand("console", "$ printf ok\n> echo side-effect\n# rm -rf /\nok")).toBe("printf ok");
    expect(runnableCommand("console", "$ echo 'a\n> b'\na\nb\n> c")).toBe("echo 'a\nb'");
    expect(runnableCommand("console", '$ echo "it\'s" # note\n> out')).toBe('echo "it\'s" # note');
  });

  test("the Run button asks before destructive commands only", () => {
    for (const command of [
      "rm -rf build",
      "git push --force origin main",
      "git reset --hard HEAD~1",
      "sudo make install",
      "kubectl delete pod web-0",
      "terraform destroy",
      "curl -fsSL https://example.com/install.sh | sh",
      "psql -c 'DROP TABLE users'",
      "kubectl --context prod delete deployment/app",
      "git -C repo push origin main --force",
      "helm --namespace web uninstall app",
      "terraform -chdir=infra destroy",
      "npm --workspace web publish",
      "bash -c 'rm -rf /'",
      'sh -c "sudo make install"',
      "echo $(rm -rf build)",
      "git push \\\n  --force origin main",
      "rm \\\n  -rf build",
    ])
      expect(runAsks(command)).toBe(true);
    for (const command of [
      "npm ci",
      "git status",
      "rm notes.txt",
      "ls -la",
      "git push origin main",
      "docker ps",
      "kubectl --context prod get pods",
      "git -C repo status",
    ])
      expect(runAsks(command)).toBe(false);
    expect(stepRisks("echo hi", "Choose either option")).toEqual(["decision"]);
  });

  test("a long doc parses in one pass", () => {
    const block = "## Step\n\nRun it:\n\n```bash\necho ok\n```\n\n";
    const source = block.repeat(5_000);
    const started = performance.now();
    expect(parseRunbook(source)).toHaveLength(5_000);
    expect(performance.now() - started).toBeLessThan(1_000);
  });
});

describe("Run all prompt", () => {
  test("lists every step as Step N of M and states the contract", () => {
    const steps = parseRunbook(fixture("deploy.md"));
    const prompt = runbookPrompt("/repo/docs/deploy.md", steps);
    expect(prompt).toStartWith("Run this runbook for me, step by step: /repo/docs/deploy.md");
    expect(prompt).toContain("1. Step 1 of 5 (Deploy the web app, line 5)\n");
    expect(prompt).toContain("4. Step 4 of 5 (Ship, line 27) ASK FIRST (destructive, a decision in the doc)");
    expect(prompt).toContain("3. Step 3 of 5 (Log in, line 19) ASK FIRST (needs credentials)");
    expect(prompt).toContain("```bash\nwrangler deploy --env production\n```");
    expect(prompt).toContain('"Step N of 5: <what it does>"');
    expect(prompt).toContain("Stop and ask me with your question tool");
    expect(prompt).toContain("When a step fails, stop.");
  });

  test("a command with backtick and tilde fences in it stays inside its own fence", () => {
    const command = "cat <<'EOF'\n```\n~~~~\nEOF";
    const prompt = runbookPrompt("/doc.md", parseRunbook(`~~~~~bash\n${command}\n~~~~~\n`));
    expect(prompt).toContain("````bash\n" + command + "\n````\n");
  });

  test("stays bounded for a long runbook, of long steps or of many short ones", () => {
    const long = parseRunbook(("```bash\n" + "echo step\n".repeat(200) + "```\n\n").repeat(400));
    const longPrompt = runbookPrompt("/doc.md", long);
    expect(longPrompt.length).toBeLessThan(60_000);
    expect(longPrompt).toMatch(/\(Steps \d+ to 400 are in the file: read them there\.\)/);
    const lead = `## Step\n\n${"If this prints a warning, read it. ".repeat(10)}\n\n\`\`\`sh\nls\n\`\`\`\n\n`;
    const short = parseRunbook(lead.repeat(5_000));
    const shortPrompt = runbookPrompt("/doc.md", short);
    expect(shortPrompt.length).toBeLessThan(60_000);
    // Wide characters count in UTF-8 bytes, the host's limit.
    const wide = parseRunbook(("```sh\necho " + "界".repeat(2_000) + "\n```\n\n").repeat(40));
    expect(new TextEncoder().encode(runbookPrompt("/doc.md", wide)).length).toBeLessThan(60_000);
    expect(shortPrompt).toMatch(/\(Steps \d+ to 5000 are in the file: read them there\.\)/);
  });
});
