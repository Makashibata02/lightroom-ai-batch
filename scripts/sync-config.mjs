#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const canonical = path.join(repoRoot, "config", "pipeline.json");
const pluginCopy = path.join(
  repoRoot,
  "plugin",
  "LightroomMCP.lrplugin",
  "config",
  "pipeline.json",
);

const canonicalText = fs.readFileSync(canonical, "utf8").replace(/\r\n/g, "\n");
JSON.parse(canonicalText);

if (process.argv.includes("--check")) {
  const pluginText = fs.readFileSync(pluginCopy, "utf8").replace(/\r\n/g, "\n");
  if (pluginText !== canonicalText) {
    console.error("pipeline config drift: run `node scripts/sync-config.mjs`");
    process.exit(1);
  }
  console.log("pipeline config is synchronized");
} else {
  fs.mkdirSync(path.dirname(pluginCopy), { recursive: true });
  fs.writeFileSync(pluginCopy, canonicalText);
  console.log(`copied ${path.relative(repoRoot, canonical)} -> ${path.relative(repoRoot, pluginCopy)}`);
}
