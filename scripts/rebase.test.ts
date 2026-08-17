import { afterEach, describe, expect, it } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { $ } from "bun";

const scriptPath = path.join(import.meta.dir, "rebase.sh");
const tempDirs: string[] = [];

interface ScriptFixture {
	binDir: string;
	ompArgsPath: string;
	ompPath: string;
	root: string;
}

interface ScriptResult {
	exitCode: number;
	stderr: string;
	stdout: string;
}

async function createConflictFixture(): Promise<ScriptFixture> {
	const root = await fs.mkdtemp(path.join(os.tmpdir(), "rebase-"));
	tempDirs.push(root);
	const binDir = path.join(root, "bin");
	const rebaseDir = path.join(root, ".git", "rebase-merge");
	await Promise.all([fs.mkdir(binDir, { recursive: true }), fs.mkdir(rebaseDir, { recursive: true })]);

	const conflictPath = "\tconflicted name ";
	const status = [`UU ${conflictPath}`, "R  renamed-new", "renamed-old", " M changed", "?? untracked", ""].join("\0");
	const gitPath = path.join(binDir, "git");
	const ompPath = path.join(binDir, "omp");
	const ompArgsPath = path.join(root, "omp-args.json");
	await Promise.all([
		Bun.write(
			gitPath,
			`#!/usr/bin/env bun
const args = Bun.argv.slice(2).join(" ");
if (args === "rev-parse --show-toplevel") process.stdout.write(${JSON.stringify(root)});
else if (args === "rev-parse --git-path rebase-session") process.stdout.write(".git/rebase-session");
else if (args === "rev-parse --git-path rebase-apply") process.stdout.write(".git/rebase-apply");
else if (args === "rev-parse --git-path rebase-merge") process.stdout.write(".git/rebase-merge");
else if (args === "branch --show-current") process.stdout.write("feature");
else if (args === "status --porcelain=v1 -z --untracked-files=normal") process.stdout.write(${JSON.stringify(status)});
else if (args === "rev-parse --verify REBASE_HEAD") process.stdout.write("deadbeef");
else if (args.startsWith("show --no-patch")) process.stdout.write("deadbee smoke conflict");
else if (args === "diff --name-only --diff-filter=U") process.stdout.write(${JSON.stringify(conflictPath)});
else { process.stderr.write("unexpected git arguments: " + args + "\\n"); process.exit(2); }
`,
		),
		Bun.write(
			ompPath,
			`#!/usr/bin/env bun
await Bun.write(${JSON.stringify(ompArgsPath)}, JSON.stringify(Bun.argv.slice(2)));
`,
		),
		Bun.write(
			path.join(root, conflictPath),
			"<<<<<<< HEAD\nmain\n=======\nfeature\n>>>>>>> branch\n<<<<<<< HEAD\nsecond-main\n=======\nsecond-feature\n>>>>>>> branch\n",
		),
		Bun.write(path.join(rebaseDir, "msgnum"), "2\n"),
		Bun.write(path.join(rebaseDir, "end"), "101\n"),
		Bun.write(path.join(rebaseDir, "head-name"), "refs/heads/feature\n"),
		Bun.write(path.join(rebaseDir, "stopped-sha"), "deadbeef\n"),
	]);
	await Promise.all([fs.chmod(gitPath, 0o755), fs.chmod(ompPath, 0o755)]);
	return { binDir, ompArgsPath, ompPath, root };
}

async function runGit(cwd: string, args: string[]): Promise<string> {
	const result = await $`git ${args}`
		.cwd(cwd)
		.env({ ...Bun.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" })
		.quiet()
		.nothrow();
	if (result.exitCode !== 0) {
		throw new Error(
			`git ${args.join(" ")} failed:\n${result.stderr.toString().trim() || result.stdout.toString().trim()}`,
		);
	}
	return result.stdout.toString().trim();
}

async function createInitialFixture(outcome: "clean" | "conflict"): Promise<ScriptFixture> {
	const container = await fs.mkdtemp(path.join(os.tmpdir(), "rebase-real-"));
	tempDirs.push(container);
	const root = path.join(container, "work");
	const remote = path.join(container, "remote.git");
	const binDir = path.join(container, "bin");
	await Promise.all([
		fs.mkdir(root, { recursive: true }),
		fs.mkdir(remote, { recursive: true }),
		fs.mkdir(binDir, { recursive: true }),
	]);
	await runGit(remote, ["init", "--bare", "--initial-branch=main", "-q"]);
	await runGit(root, ["init", "--initial-branch=main", "-q"]);
	await runGit(root, ["config", "user.email", "rebase@example.test"]);
	await runGit(root, ["config", "user.name", "Rebase Test"]);
	await Bun.write(path.join(root, "conflicted.txt"), "base\n");
	await runGit(root, ["add", "conflicted.txt"]);
	await runGit(root, ["commit", "-qm", "base"]);
	await runGit(root, ["remote", "add", "origin", remote]);
	await runGit(root, ["push", "-qu", "origin", "main"]);
	await runGit(root, ["checkout", "-qb", "feature"]);
	if (outcome === "conflict") {
		await Bun.write(path.join(root, "conflicted.txt"), "feature\n");
		await runGit(root, ["add", "conflicted.txt"]);
	} else {
		await Bun.write(path.join(root, "feature.txt"), "feature\n");
		await runGit(root, ["add", "feature.txt"]);
	}
	await runGit(root, ["commit", "-qm", "feature"]);
	await runGit(root, ["checkout", "-q", "main"]);
	await Bun.write(path.join(root, "conflicted.txt"), "upstream\n");
	await runGit(root, ["add", "conflicted.txt"]);
	await runGit(root, ["commit", "-qm", "upstream"]);
	await runGit(root, ["push", "-q", "origin", "main"]);
	await runGit(root, ["checkout", "-q", "feature"]);

	const ompPath = path.join(binDir, "omp");
	const ompArgsPath = path.join(container, "omp-args.json");
	await Bun.write(
		ompPath,
		`#!/usr/bin/env bun
await Bun.write(${JSON.stringify(ompArgsPath)}, JSON.stringify(Bun.argv.slice(2)));
`,
	);
	await fs.chmod(ompPath, 0o755);
	return { binDir, ompArgsPath, ompPath, root };
}

async function runScript(fixture: ScriptFixture): Promise<ScriptResult> {
	const child = Bun.spawn(
		[scriptPath, "origin/main", "--omp", fixture.ompPath, "--max-time", "1s"],
		{
			cwd: fixture.root,
			env: {
				...Bun.env,
				GIT_CONFIG_GLOBAL: "/dev/null",
				GIT_CONFIG_SYSTEM: "/dev/null",
				PATH: `${fixture.binDir}${path.delimiter}${Bun.env.PATH ?? ""}`,
			},
			stdout: "pipe",
			stderr: "pipe",
		},
	);
	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(child.stdout).text(),
		new Response(child.stderr).text(),
		child.exited,
	]);
	return { exitCode, stderr, stdout };
}

afterEach(async () => {
	await Promise.all(tempDirs.splice(0).map(dir => fs.rm(dir, { recursive: true, force: true })));
});

describe("scripts/rebase.sh", () => {
	it("reports active conflict blocks without restarting the rebase or resuming an old session", async () => {
		const fixture = await createConflictFixture();
		const { exitCode, stderr, stdout } = await runScript(fixture);
		const firstOmpArgs: string[] = await Bun.file(fixture.ompArgsPath).json();

		expect(exitCode).toBe(1);
		expect(stdout).not.toContain("preflight:");
		expect(stdout).toContain("rebase 2/101 (1%)");
		expect(stdout).toContain("conflicts=1 | blocks=2 | staged=1 | unstaged=1 | untracked=1");
		expect(stdout).toMatch(/\| idle=\d{2}:\d{2}:\d{2} \|/);
		expect(stdout).toContain(`files=${JSON.stringify("\tconflicted name ")}`);
		const firstSessionDir = firstOmpArgs[firstOmpArgs.indexOf("--session-dir") + 1];
		const renderedPrompt = firstOmpArgs[firstOmpArgs.length - 1];
		expect(renderedPrompt).toContain("Rebase the current branch onto `origin/main`");
		expect(renderedPrompt).not.toContain("{{");
		const secondRun = await runScript(fixture);
		const secondOmpArgs: string[] = await Bun.file(fixture.ompArgsPath).json();
		const secondSessionDir = secondOmpArgs[secondOmpArgs.indexOf("--session-dir") + 1];
		expect(secondRun.exitCode).toBe(1);
		expect(firstSessionDir).toContain(`${path.sep}rebase-session${path.sep}run-`);
		expect(secondSessionDir).not.toBe(firstSessionDir);
		expect(firstOmpArgs).not.toContain("--continue");
		expect(firstOmpArgs).toContain("--session-dir");
		expect(stderr).toContain("OMP exited before completing the rebase and did not record a decision request");
	});

	it("fetches and completes a clean initial rebase without launching OMP", async () => {
		const fixture = await createInitialFixture("clean");
		const { exitCode, stderr, stdout } = await runScript(fixture);

		expect(exitCode).toBe(0);
		expect(stdout).toContain("preflight: fetching origin for origin/main");
		expect(stdout).toContain("preflight: starting git rebase origin/main");
		expect(stdout).toContain("Rebase onto origin/main completed without conflicts.");
		expect(stderr).toBe("");
		expect(await Bun.file(fixture.ompArgsPath).exists()).toBe(false);
		expect(await runGit(fixture.root, ["branch", "--show-current"])).toBe("feature");
		expect(await Bun.file(path.join(fixture.root, ".git", "rebase-merge", "msgnum")).exists()).toBe(false);
	});

	it("launches a fresh resolver when the initial rebase stops on conflicts", async () => {
		const fixture = await createInitialFixture("conflict");
		const { exitCode, stderr, stdout } = await runScript(fixture);
		const ompArgs: string[] = await Bun.file(fixture.ompArgsPath).json();

		expect(exitCode).toBe(1);
		expect(stdout).toContain("preflight: starting git rebase origin/main");
		expect(stdout).toMatch(/rebase \d+\/\d+ \(\d+%\)/);
		expect(stdout).toContain("conflicts=1 | blocks=1");
		expect(await runGit(fixture.root, ["status", "--short"])).toContain("UU conflicted.txt");
		expect(await Bun.file(path.join(fixture.root, ".git", "rebase-merge", "msgnum")).exists()).toBe(true);
		expect(ompArgs).not.toContain("--continue");
		expect(stderr).toContain("OMP exited before completing the rebase and did not record a decision request");
	});
});
