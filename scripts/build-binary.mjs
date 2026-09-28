#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { execSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const serverDir = path.join(repoRoot, "server");
const outDir = path.join(repoRoot, "build", "bin");

const log = (m) => console.log(`[build-binary] ${m}`);

const TARGETS = parseTargets();

function parseTargets() {
  const arg = process.argv.slice(2).find((a) => a.startsWith("--targets="));
  if (arg) {
    return arg.slice("--targets=".length).split(",").map((t) => t.trim()).filter(Boolean);
  }
  if (process.env.BUILD_TARGETS) {
    return process.env.BUILD_TARGETS.split(",").map((t) => t.trim()).filter(Boolean);
  }
  return [
    "bun-windows-x64",
  ];
}

function which(bin) {
  try {
    return execSync(process.platform === "win32" ? `where ${bin}` : `command -v ${bin}`, {
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .split(/\r?\n/)[0]
      .trim();
  } catch {
    return "";
  }
}

const bunPath = process.env.BUN_EXE || which("bun") || which("bun.exe");
if (!bunPath) {
  console.error(
    "[build-binary] bun not found on PATH. Install via mise (`mise install`) or https://bun.sh.",
  );
  process.exit(1);
}
log(`using bun at ${bunPath}`);

const tscPath = path.join(serverDir, "node_modules", "@typescript", "native", "bin", "tsc");
if (!fs.existsSync(tscPath)) {
  console.error("[build-binary] server/node_modules is missing. Run `npm ci` in server/ first.");
  process.exit(1);
}
log(`$ node ${path.relative(repoRoot, tscPath)}`);
const tscResult = spawnSync(process.execPath, [tscPath], { cwd: serverDir, stdio: "inherit" });
if (tscResult.status !== 0) {
  console.error("[build-binary] TypeScript build failed");
  process.exit(tscResult.status ?? 1);
}

fs.mkdirSync(outDir, { recursive: true });

const entry = path.join(serverDir, "dist", "index.js");
if (!fs.existsSync(entry)) {
  console.error(`[build-binary] missing ${entry}; tsc did not emit dist/index.js`);
  process.exit(1);
}

for (const target of TARGETS) {
  const ext = target.includes("windows") ? ".exe" : "";
  const name = `lightroom-ai-batch-mcp-${target.replace(/^bun-/, "")}${ext}`;
  const outPath = path.join(outDir, name);
  log(`compiling ${target} → ${path.relative(repoRoot, outPath)}`);
  const result = spawnSync(
    bunPath,
    ["build", "--compile", `--target=${target}`, entry, "--outfile", outPath],
    { stdio: "inherit", cwd: serverDir },
  );
  if (result.status !== 0) {
    console.error(`[build-binary] bun build failed for target ${target}`);
    process.exit(result.status ?? 1);
  }
}

log(`done. binaries in ${path.relative(repoRoot, outDir)}/`);
