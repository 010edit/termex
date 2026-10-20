#!/usr/bin/env bash
#
# flutter_rust_bridge codegen runner
#
# Generates Dart bindings from crates/termex-flutter-bridge/src/api/*.rs
# into crates/termex-flutter-bridge/lib/src/generated/.
#
# Requirements:
#   - Rust toolchain (stable)
#   - Flutter SDK (>= 3.24)
#   - flutter_rust_bridge_codegen (cargo install --version '=2.12.0')
#
# Usage:
#   ./scripts/frb-codegen.sh          # regenerate bindings
#   ./scripts/frb-codegen.sh --check  # verify current bindings are up-to-date (CI)

set -euo pipefail

cd "$(dirname "$0")/.."

# ── PATH sanitisation (v0.79.37) ──
# Strip FVM from PATH if present. The `flutter_rust_bridge_codegen` invokes
# `flutter --version` under the hood; when that resolves to FVM's `fvm.aot`
# wrapper, the subprocess can deadlock for 20+ minutes (observed v0.79.19).
# Resolving directly to the user's installed flutter (or a clean PATH on
# CI) sidesteps the deadlock entirely.
if command -v fvm >/dev/null 2>&1; then
  FVM_BIN="$(command -v fvm)"
  FVM_DIR="$(dirname "$FVM_BIN")"
  # Remove every occurrence of FVM's directory from PATH segments.
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v "^${FVM_DIR}\$" | paste -sd ':' -)"
  export PATH
fi

# ── Tool checks ──
if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  echo "❌ flutter_rust_bridge_codegen not installed."
  echo "   Run: cargo install flutter_rust_bridge_codegen --version '=2.12.0'"
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "❌ flutter not on PATH. Install via https://docs.flutter.dev/get-started/install"
  exit 1
fi

# ── Flutter pub get (needed for codegen to resolve types) ──
(cd app && flutter pub get >/dev/null)

# ── Run codegen ──
CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_MODE=1
fi

echo "▶ Generating FRB bindings..."
flutter_rust_bridge_codegen generate --no-deps-check --no-auto-upgrade-dependency

if [[ $CHECK_MODE -eq 1 ]]; then
  # All paths codegen touches. Keep in sync with the regen behaviour above.
  CHECK_PATHS=(
    crates/termex-flutter-bridge/lib/src/generated/
    crates/termex-flutter-bridge/include/
    crates/termex-flutter-bridge/src/frb_generated.rs
  )
  # v0.79.44: quiet probe first (no output on success / no diff dump on
  # failure), then emit a readable digest. The raw `--exit-code` dump
  # used to spam the CI log with 1000+ lines of regenerated Dart on a
  # single drift — making the failure summary hard to find.
  if git diff --quiet -- "${CHECK_PATHS[@]}" 2>/dev/null; then
    echo "✅ FRB bindings are up-to-date."
  else
    echo
    echo "── FRB drift detected (files): ─────────────────────────"
    git diff --stat -- "${CHECK_PATHS[@]}" || true
    echo
    echo "── First 50 lines of drift: ────────────────────────────"
    # Cap the diff so the CI summary stays readable. Devs can re-run
    # locally for the full picture.
    git diff -- "${CHECK_PATHS[@]}" 2>/dev/null | head -50 || true
    echo "── (truncated; run \`./scripts/frb-codegen.sh --check\` locally for full diff) ──"
    echo
    echo "❌ FRB bindings are out of date."
    echo "   Fix locally: ./scripts/frb-codegen.sh && git add -A && commit"
    exit 1
  fi
else
  echo "✅ Regenerated FRB bindings."
  echo "   Review changes with: git diff app/lib/src/"
fi
