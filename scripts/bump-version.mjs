#!/usr/bin/env node

/**
 * Synchronizes version across all version-carrying files (Flutter + Rust
 * workspace layout).
 *
 * Usage:
 *   node scripts/bump-version.mjs patch    # 0.80.0 → 0.80.1
 *   node scripts/bump-version.mjs minor    # 0.80.0 → 0.81.0
 *   node scripts/bump-version.mjs major    # 0.80.0 → 1.0.0
 *   node scripts/bump-version.mjs 0.81.0   # explicit version
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");

const JSON_FILES = [
  resolve(root, "package.json"),
];

const CARGO_FILES = [
  resolve(root, "crates/termex-core/Cargo.toml"),
  resolve(root, "crates/termex-flutter-bridge/Cargo.toml"),
];

const PUBSPEC = resolve(root, "app/pubspec.yaml");

// Dart-side version constant consumed by the auto-update service
// (appcast comparison). Falling out of sync here makes the updater
// think every release is "new" (or none are) — see v0.79.0 B-2 fix.
const APP_VERSION_DART = resolve(
  root,
  "packages/termex_shared/lib/app_version.dart",
);

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf-8"));
}

function writeJson(path, data) {
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
}

function bumpVersion(current, type) {
  const [major, minor, patch] = current.split(".").map(Number);
  switch (type) {
    case "major":
      return `${major + 1}.0.0`;
    case "minor":
      return `${major}.${minor + 1}.0`;
    case "patch":
      return `${major}.${minor}.${patch + 1}`;
    default:
      if (/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$/.test(type)) return type;
      console.error(`Invalid version or bump type: ${type}`);
      process.exit(1);
  }
}

function updateCargo(path, version) {
  if (!existsSync(path)) return false;
  let text = readFileSync(path, "utf-8");
  text = text.replace(/^version\s*=\s*"[^"]+"/m, `version = "${version}"`);
  writeFileSync(path, text);
  return true;
}

function updatePubspec(path, version) {
  if (!existsSync(path)) return false;
  let text = readFileSync(path, "utf-8");
  // pubspec uses `version: 0.49.0+1` (semver + build number)
  text = text.replace(/^version:\s*[^\s]+/m, `version: ${version}+1`);
  writeFileSync(path, text);
  return true;
}

// ── Main ───────────────────────────────────────────────────────

const arg = process.argv[2];
if (!arg) {
  console.error("Usage: node bump-version.mjs <patch|minor|major|x.y.z>");
  process.exit(1);
}

const pkg = readJson(JSON_FILES[0]);
const currentVersion = pkg.version;
const newVersion = bumpVersion(currentVersion, arg);

console.log(`Bumping version: ${currentVersion} → ${newVersion}`);

for (const file of JSON_FILES) {
  const label = file.replace(root + "/", "");
  if (!existsSync(file)) {
    console.log(`  ⏭  ${label} (skipped, not present)`);
    continue;
  }
  const data = readJson(file);
  data.version = newVersion;
  writeJson(file, data);
  console.log(`  ✓ ${label}`);
}

for (const file of CARGO_FILES) {
  const label = file.replace(root + "/", "");
  if (updateCargo(file, newVersion)) {
    console.log(`  ✓ ${label}`);
  } else {
    console.log(`  ⏭  ${label} (skipped, not present)`);
  }
}

const pubspecLabel = PUBSPEC.replace(root + "/", "");
if (updatePubspec(PUBSPEC, newVersion)) {
  console.log(`  ✓ ${pubspecLabel}`);
} else {
  console.log(`  ⏭  ${pubspecLabel} (skipped, not present)`);
}

const appVersionLabel = APP_VERSION_DART.replace(root + "/", "");
if (existsSync(APP_VERSION_DART)) {
  let dart = readFileSync(APP_VERSION_DART, "utf-8");
  dart = dart.replace(
    /const String kAppVersion = '[^']+';/,
    `const String kAppVersion = '${newVersion}';`,
  );
  writeFileSync(APP_VERSION_DART, dart);
  console.log(`  ✓ ${appVersionLabel}`);
} else {
  console.log(`  ⏭  ${appVersionLabel} (skipped, not present)`);
}

console.log(`\nNext steps:`);
console.log(`  git add -A && git commit -m "chore: release v${newVersion}"`);
console.log(`  git tag v${newVersion}`);
console.log(`  git push origin main --tags`);
