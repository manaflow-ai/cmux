#!/usr/bin/env bun

import * as fs from "node:fs/promises";
import * as path from "node:path";
import { $ } from "bun";

const DEFAULT_TARGET = "upstream/main";
const DEFAULT_MAX_TIME = "2h";
const TARGET_PATTERN = /^(?!-)[A-Za-z0-9._/@+~-]+$/;
const DURATION_PATTERN = /^\d+(?:\.\d+)?[smh]?$/;
const PROGRESS_POLL_MS = 5_000;
const PROGRESS_HEARTBEAT_MS = 30_000;
const PROGRESS_STALL_MS = 5 * 60_000;
const MAX_PROGRESS_PATHS = 5;
const CONFLICT_STATUSES: Record<string, true> = {
	AA: true,
	AU: true,
	DD: true,
	DU: true,
	UA: true,
	UD: true,
	UU: true,
};

interface CliOptions {
	dryRun: boolean;
	maxTime: string;
	ompBin: string;
	target: string;
}

interface RebaseStatePaths {
	apply: string;
	merge: string;
}

interface WorktreeProgress {
	conflicts: string[];
	conflictBlocks: number;
	staged: number;
	unstaged: number;
	untracked: number;
}

interface RebaseProgress extends WorktreeProgress {
	active: boolean;
	branch?: string;
	commit?: string;
	step?: number;
	total?: number;
}

function printUsage(): void {
	process.stdout.write(
		[
			"Usage: scripts/rebase.sh [target] [options]",
			"",
			"Runs OMP headlessly with full tool approval to rebase the current branch.",
			"Ambiguous semantic conflicts are written to rebase-conflict.md.",
			"Answer that file and run this command again; OMP records the precedent in resolve.md.",
			"",
			"Arguments:",
			`  target                 Rebase target (default: ${DEFAULT_TARGET})`,
			"",
			"Options:",
			"  --omp <executable>     OMP executable (default: $REBASE_OMP_BIN or omp)",
			`  --max-time <duration>  OMP deadline (default: ${DEFAULT_MAX_TIME})`,
			"  --dry-run              Print the resolved invocation and prompt without running OMP",
			"  -h, --help             Show this help",
			"",
		].join("\n"),
	);
}

function fail(message: string): never {
	process.stderr.write(`${message}\n`);
	process.exit(1);
}

function nextValue(argv: string[], index: number, flag: string): string {
	const value = argv[index + 1];
	if (!value || value.startsWith("--")) fail(`${flag} requires a value`);
	return value;
}

function parseArgs(argv: string[]): CliOptions {
	const options: CliOptions = {
		dryRun: false,
		maxTime: Bun.env.REBASE_MAX_TIME ?? DEFAULT_MAX_TIME,
		ompBin: Bun.env.REBASE_OMP_BIN ?? "omp",
		target: DEFAULT_TARGET,
	};
	let positionalTarget: string | undefined;

	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		if (arg === "--help" || arg === "-h") {
			printUsage();
			process.exit(0);
		}

		switch (arg) {
			case "--dry-run":
				options.dryRun = true;
				break;
			case "--max-time":
				options.maxTime = nextValue(argv, index, arg);
				index += 1;
				break;
			case "--omp":
				options.ompBin = nextValue(argv, index, arg);
				index += 1;
				break;
			default:
				if (arg.startsWith("-")) fail(`Unknown option: ${arg}`);
				if (positionalTarget) fail(`Unexpected argument: ${arg}`);
				positionalTarget = arg;
		}
	}

	if (positionalTarget) options.target = positionalTarget;
	if (!TARGET_PATTERN.test(options.target)) {
		fail(`Invalid target: ${options.target}`);
	}
	if (!DURATION_PATTERN.test(options.maxTime)) {
		fail(`Invalid --max-time duration: ${options.maxTime}`);
	}
	if (!options.ompBin.trim()) fail("OMP executable cannot be empty");
	return options;
}

async function gitOutput(cwd: string, args: string[]): Promise<string> {
	const result = await $`git ${args}`.cwd(cwd).quiet().nothrow();
	if (result.exitCode !== 0) {
		const detail = result.stderr.toString().trim();
		fail(detail || `git ${args.join(" ")} failed`);
	}
	return result.stdout.toString().trim();
}

async function pathExists(filePath: string): Promise<boolean> {
	try {
		await fs.stat(filePath);
		return true;
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
		throw error;
	}
}

async function readOptionalText(filePath: string): Promise<string | undefined> {
	try {
		return (await Bun.file(filePath).text()).trim();
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
		throw error;
	}
}

async function gitOutputOptional(cwd: string, args: string[], trim = true): Promise<string | undefined> {
	const result = await $`git ${args}`.cwd(cwd).quiet().nothrow();
	if (result.exitCode !== 0) return undefined;
	const output = result.stdout.toString();
	return trim ? output.trim() : output;
}

function parsePositiveInteger(value: string | undefined): number | undefined {
	if (!value) return undefined;
	const parsed = Number.parseInt(value, 10);
	return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

function countConflictBlocks(content: string): number {
	let count = 0;
	let offset = content.indexOf("<<<<<<< ");
	while (offset !== -1) {
		if (offset === 0 || content.charCodeAt(offset - 1) === 10) count += 1;
		offset = content.indexOf("<<<<<<< ", offset + 8);
	}
	return count;
}

async function readConflictBlockCount(root: string, conflicts: string[]): Promise<number> {
	const counts = await Promise.all(
		conflicts.map(async filePath => {
			try {
				return countConflictBlocks(await Bun.file(path.resolve(root, filePath)).text());
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
				throw error;
			}
		}),
	);
	return counts.reduce((total, count) => total + count, 0);
}

function parseWorktreeProgress(status: string): WorktreeProgress {
	const progress: WorktreeProgress = {
		conflicts: [],
		conflictBlocks: 0,
		staged: 0,
		unstaged: 0,
		untracked: 0,
	};
	const entries = status.split("\0");
	for (let index = 0; index < entries.length; index += 1) {
		const entry = entries[index];
		if (!entry) continue;
		const code = entry.slice(0, 2);
		if (code === "??") {
			progress.untracked += 1;
		} else if (CONFLICT_STATUSES[code]) {
			progress.conflicts.push(entry.slice(3));
		} else {
			if (code[0] !== " ") progress.staged += 1;
			if (code[1] !== " ") progress.unstaged += 1;
		}
		if (code.includes("R") || code.includes("C")) index += 1;
	}
	return progress;
}

async function startInitialRebase(root: string, target: string, paths: RebaseStatePaths): Promise<void> {
	const [mergeActive, applyActive] = await Promise.all([pathExists(paths.merge), pathExists(paths.apply)]);
	if (mergeActive || applyActive) return;

	const separator = target.indexOf("/");
	if (separator > 0) {
		const remote = target.slice(0, separator);
		if (await gitOutputOptional(root, ["remote", "get-url", remote])) {
			process.stdout.write(`[rebase] preflight: fetching ${remote} for ${target}\n`);
			const fetchResult = await $`git fetch ${remote}`.cwd(root).quiet().nothrow();
			if (fetchResult.exitCode !== 0) {
				const detail = fetchResult.stderr.toString().trim() || fetchResult.stdout.toString().trim();
				fail(detail || `git fetch ${remote} failed`);
			}
		}
	}

	process.stdout.write(`[rebase] preflight: starting git rebase ${target}\n`);
	const rebaseResult = await $`GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true git rebase ${target}`
		.cwd(root)
		.quiet()
		.nothrow();
	if (rebaseResult.exitCode === 0) return;

	const [rebaseMergeActive, rebaseApplyActive, unmerged] = await Promise.all([
		pathExists(paths.merge),
		pathExists(paths.apply),
		gitOutputOptional(root, ["diff", "--name-only", "--diff-filter=U"]),
	]);
	if (rebaseMergeActive || rebaseApplyActive || unmerged) return;

	const detail = rebaseResult.stderr.toString().trim() || rebaseResult.stdout.toString().trim();
	fail(detail || `git rebase ${target} failed`);
}

async function readRebaseProgress(root: string, paths: RebaseStatePaths): Promise<RebaseProgress> {
	const [mergeActive, applyActive, status] = await Promise.all([
		pathExists(paths.merge),
		pathExists(paths.apply),
		gitOutputOptional(root, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], false),
	]);
	if (status === undefined) throw new Error("git status failed while reading rebase progress");
	const stateDir = mergeActive ? paths.merge : applyActive ? paths.apply : undefined;
	const parsedWorktree = parseWorktreeProgress(status);
	const worktree = {
		...parsedWorktree,
		conflictBlocks: await readConflictBlockCount(root, parsedWorktree.conflicts),
	};
	if (!stateDir) {
		const branch = await gitOutputOptional(root, ["branch", "--show-current"]);
		return { ...worktree, active: false, branch: branch || undefined };
	}

	const isMergeBackend = stateDir === paths.merge;
	const [stepText, totalText, headName, rebaseHead, metadataHead] = await Promise.all([
		readOptionalText(path.join(stateDir, isMergeBackend ? "msgnum" : "next")),
		readOptionalText(path.join(stateDir, isMergeBackend ? "end" : "last")),
		readOptionalText(path.join(stateDir, "head-name")),
		gitOutputOptional(root, ["rev-parse", "--verify", "REBASE_HEAD"]),
		readOptionalText(path.join(stateDir, isMergeBackend ? "stopped-sha" : "original-commit")),
	]);
	const commitSha = rebaseHead || metadataHead;
	const commit = commitSha
		? await gitOutputOptional(root, ["show", "--no-patch", "--format=%h %s", commitSha])
		: undefined;
	return {
		...worktree,
		active: true,
		branch: headName?.replace(/^refs\/heads\//, ""),
		commit,
		step: parsePositiveInteger(stepText),
		total: parsePositiveInteger(totalText),
	};
}

function formatElapsed(elapsedMs: number): string {
	const totalSeconds = Math.floor(elapsedMs / 1_000);
	const hours = Math.floor(totalSeconds / 3_600);
	const minutes = Math.floor((totalSeconds % 3_600) / 60);
	const seconds = totalSeconds % 60;
	return [hours, minutes, seconds].map(value => value.toString().padStart(2, "0")).join(":");
}

function formatProgressPaths(paths: string[]): string {
	const visible = paths
		.slice(0, MAX_PROGRESS_PATHS)
		.map(filePath => (/[\t\r\n]/.test(filePath) ? JSON.stringify(filePath) : filePath));
	const remaining = paths.length - visible.length;
	return remaining > 0 ? `${visible.join(", ")} (+${remaining} more)` : visible.join(", ");
}

function describeRebaseProgress(progress: RebaseProgress, idleMs: number): string {
	const phase =
		progress.active && progress.step && progress.total
			? `rebase ${progress.step}/${progress.total} (${Math.floor((progress.step / progress.total) * 100)}%)`
			: progress.active
				? "rebase active"
				: "rebase not active";
	const details = [phase];
	if (progress.branch) details.push(`branch=${progress.branch}`);
	if (progress.commit) details.push(`commit=${progress.commit}`);
	details.push(
		`conflicts=${progress.conflicts.length}`,
		`blocks=${progress.conflictBlocks}`,
		`staged=${progress.staged}`,
		`unstaged=${progress.unstaged}`,
		`untracked=${progress.untracked}`,
		`idle=${formatElapsed(idleMs)}`,
	);
	if (progress.conflicts.length > 0) details.push(`files=${formatProgressPaths(progress.conflicts)}`);
	return details.join(" | ");
}

async function startProgressReporter(root: string, paths: RebaseStatePaths): Promise<() => Promise<void>> {
	const startedAt = Date.now();
	let lastProgressAt = startedAt;
	let lastPrintedAt = 0;
	let previousSignature = "";
	let pendingReport = Promise.resolve();

	const report = async (force: boolean, label?: string): Promise<void> => {
		try {
			const progress = await readRebaseProgress(root, paths);
			const signature = JSON.stringify(progress);
			const now = Date.now();
			const changed = signature !== previousSignature;
			if (changed) lastProgressAt = now;
			const idleMs = now - lastProgressAt;
			if (!force && !changed && now - lastPrintedAt < PROGRESS_HEARTBEAT_MS) return;
			const event = label ?? (changed ? "progress" : idleMs >= PROGRESS_STALL_MS ? "stalled" : "heartbeat");
			process.stdout.write(
				`[rebase ${formatElapsed(now - startedAt)}] ${event}: ${describeRebaseProgress(progress, idleMs)}\n`,
			);
			previousSignature = signature;
			lastPrintedAt = now;
		} catch (error) {
			process.stderr.write(
				`[rebase ${formatElapsed(Date.now() - startedAt)}] unable to read progress: ${String(error)}\n`,
			);
		}
	};

	await report(true, "initial");
	const timer = setInterval(() => {
		pendingReport = pendingReport.then(() => report(false));
	}, PROGRESS_POLL_MS);
	return async () => {
		clearInterval(timer);
		await pendingReport;
		await report(true, "final");
	};
}

async function main(): Promise<void> {
	const options = parseArgs(Bun.argv.slice(2));
	const root = path.resolve(await gitOutput(process.cwd(), ["rev-parse", "--show-toplevel"]));
	const initialBranch = await gitOutputOptional(root, ["branch", "--show-current"]);
	const gitSessionPath = await gitOutput(root, ["rev-parse", "--git-path", "rebase-session"]);
	const sessionRoot = path.resolve(root, gitSessionPath);
	const sessionDir = path.join(sessionRoot, `run-${Bun.randomUUIDv7()}`);
	const notesPath = path.join(root, "resolve.md");
	const conflictPath = path.join(root, "rebase-conflict.md");
	const rebasePaths: RebaseStatePaths = {
		apply: path.resolve(root, await gitOutput(root, ["rev-parse", "--git-path", "rebase-apply"])),
		merge: path.resolve(root, await gitOutput(root, ["rev-parse", "--git-path", "rebase-merge"])),
	};
	const promptTemplate = await Bun.file(path.join(import.meta.dir, "rebase-prompt.md")).text();
	const prompt = promptTemplate
		.replace(/\{\{conflictPath\}\}/g, path.relative(root, conflictPath))
		.replace(/\{\{notesPath\}\}/g, path.relative(root, notesPath))
		.replace(/\{\{target\}\}/g, options.target);
	const ompArgs = [
		"--cwd",
		root,
		"--session-dir",
		sessionDir,
		"--print",
		"--yolo",
		"--approval-mode",
		"yolo",
		"--no-title",
		"--max-time",
		options.maxTime,
		prompt,
	];

	if (options.dryRun) {
		process.stdout.write(
			`${JSON.stringify(
				{
					branch: initialBranch || "(detached)",
					command: [options.ompBin, ...ompArgs.slice(0, -1), "<rendered-prompt>"],
					conflictPath,
					notesPath,
					root,
					sessionDir,
					maxTime: options.maxTime,
					target: options.target,
				},
				null,
				2,
			)}\n\n${prompt}\n`,
		);
		return;
	}

	process.stdout.write(
		`${[
			`[rebase] root=${root}`,
			`[rebase] branch=${initialBranch || "(detached)"} target=${options.target} max-time=${options.maxTime}`,
			`[rebase] executable=${options.ompBin} session-dir=${path.relative(root, sessionDir)} mode=fresh`,
		].join("\n")}\n`,
	);

	const hasDecisionFile = await pathExists(conflictPath);
	if (!hasDecisionFile) await startInitialRebase(root, options.target, rebasePaths);
	const preflightProgress = await readRebaseProgress(root, rebasePaths);
	if (!preflightProgress.active) {
		if (hasDecisionFile) {
			process.stderr.write(
				`Rebase decision file exists without an active rebase: ${path.relative(root, conflictPath)}\n`,
			);
			process.exit(2);
		}
		if (preflightProgress.conflicts.length > 0) {
			fail("Unmerged files exist outside an active rebase");
		}
		process.stdout.write(`Rebase onto ${options.target} completed without conflicts.\n`);
		return;
	}

	const stopProgressReporter = await startProgressReporter(root, rebasePaths);

	let subprocess: Bun.Subprocess;
	try {
		subprocess = Bun.spawn([options.ompBin, ...ompArgs], {
			cwd: root,
			env: {
				...Bun.env,
				GIT_EDITOR: "true",
				GIT_SEQUENCE_EDITOR: "true",
			},
			stdin: "inherit",
			stdout: "inherit",
			stderr: "inherit",
		});
		process.stdout.write(`[rebase] resolver pid=${subprocess.pid}\n`);
	} catch (error) {
		await stopProgressReporter();
		fail(`Unable to start ${options.ompBin}: ${String(error)}`);
	}

	const exitCode = await subprocess.exited;
	await stopProgressReporter();
	if (await pathExists(conflictPath)) {
		process.stderr.write(
			`Rebase needs a semantic decision. Answer ${path.relative(root, conflictPath)} and run this command again.\n`,
		);
		process.exit(2);
	}

	const rebaseMergePath = rebasePaths.merge;
	const rebaseApplyPath = rebasePaths.apply;
	const unmerged = await gitOutput(root, ["diff", "--name-only", "--diff-filter=U"]);
	if ((await pathExists(rebaseMergePath)) || (await pathExists(rebaseApplyPath)) || unmerged) {
		fail("OMP exited before completing the rebase and did not record a decision request");
	}
	if (exitCode !== 0) process.exit(exitCode);

	process.stdout.write(`Rebase onto ${options.target} completed without unresolved decisions.\n`);
}

await main();
