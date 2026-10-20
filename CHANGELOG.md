# Changelog

All notable changes to Termex are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased] — Legacy Tauri/Vue removal

### Removed

- **`src/` (Vue 3 + Element Plus) and `src-tauri/` (Tauri v2)** — the
  retired desktop stack is physically gone. Recover it from tags
  `<= v0.79.x` if a forensic build is ever needed.
- Root Vue/Vite build chain: `index.html`, `vite.config.ts`, `tsconfig*.json`,
  `tailwind.config.ts`, `postcss.config.js`, `pnpm-lock.yaml`,
  `pnpm-workspace.yaml`.
- Tauri-only scripts: `scripts/legacy/build-tauri.sh`,
  `scripts/parity-launch.sh`, `scripts/generate-icons.mjs`,
  `scripts/setup-dev-environment.sh`,
  `scripts/download-llama-server-binaries.sh`.
- One-off Vue→Flutter i18n migration helpers that read the deleted
  `src/i18n/locales`: `scripts/i18n-diff.ts`, `scripts/i18n-merge.mjs`.
- Unused Flutter `tauri_retirement_banner.dart`.
- npm dependency tree — `package.json` now contains only the
  `version:bump` helper and no runtime/dev dependencies.

### Changed

- `Cargo.toml` workspace no longer references `src-tauri`; it contains only
  `termex-core`, `termex-flutter-bridge`, and `termexd`.
- `scripts/bump-version.mjs` no longer looks for the deleted
  `crates/termex-tauri` manifest.
- CI/release workflows, README, CLAUDE.md, and architecture docs describe the
  Flutter-only stack. Historical migration/design docs are marked as such.
- macOS entitlement comments no longer describe the removed Tauri build.
- CI: iOS/Android bootstrap checks moved out of `ci.yml` into the
  path-filtered `mobile-ci.yml`. They now run only for mobile/shared/Rust
  changes, manual dispatches, and a weekly dependency-drift canary, instead
  of on every push. Desktop `ci.yml` stays fast.

---

## [0.80.0] — 2026-08-18 — Session recording, sidebar search, context menus

First feature release on the Flutter desktop stack after the v0.79.0 cutover.

### Added

- **Session recording, migrated in full from the Tauri build**: the record
  control is back in the terminal pane, output is captured off the SSH stream
  into asciicast v2, and a per-server auto-record setting starts capture on
  connect. Auto-started recordings are badged as such in the list.
- **Playback**: recordings replay in a tab of their own — styled apart from
  live sessions so a replay is never mistaken for a shell — with play/pause,
  seek and 0.5×–4× speed. The opening screen is seeded into the recording so a
  replay no longer starts on a black terminal waiting for the first keystroke.
- **Collapsible sidebar search**: the search field now sits behind a toggle
  next to `+` across every category panel, rather than permanently occupying a
  row.
- **Sidebar context menus restored**: right-clicking a server node offers the
  legacy actions (edit, duplicate, delete, connect variants); the blank area
  below the list has its own menu again.
- **SFTP context menu**: rename, delete, new folder, copy path and refresh,
  drawn with the shared menu widget.

### Fixed

- **SFTP could not connect** — `ensure_sftp` held a DashMap shard lock across
  an `.await`, deadlocking the channel open. Both panes sat on a spinner
  indefinitely.
- **SFTP panes**: refresh after a transfer completes, single-click selects one
  row instead of accumulating a multi-selection, and metadata columns are
  dropped by the pane's own width so a docked panel no longer overflows.
- **Recording metadata**: duration and event count were never written back, so
  every row read "0s · 0 events"; deleting a recording left its `.cast` file
  on disk forever.
- **Playback layout**: the player kept the fixed height it was given for the
  dialog it first shipped in, and its content could paint over the tab strip.
- **Snippets**: creating one opens a dialog instead of erroring inside the
  panel.
- **Settings**: shorter title bar, and the redundant search box removed.
- **CI**: iOS and Android release builds repaired (core library desugaring,
  FRB codegen on the iOS runner, store credentials resolved through job env).

---

## [0.79.0] — 2026-06-08 — Desktop release candidate (parity + cutover consolidated)

> Consolidates the v0.77.0 parity close-out and v0.78.0 cutover work below
> into the first release-candidate version stamp. All version stamps
> (package.json / termex-core / termex-flutter-bridge / app pubspec /
> app_version.dart) aligned to 0.79.0 by `pnpm version:bump`.

### Fixed (release blockers)

- **B-1 Auto-update wired**: `updateServiceProvider` + HTTPS appcast fetcher now
  injected in `app/lib/main.dart` `ProviderScope.overrides` — per-platform
  `Mac/Windows/LinuxAutoUpdater` selected at boot. Previously the About tab's
  "检查更新" button threw `UnimplementedError` at runtime.
- **B-2 Version stamps aligned**: pubspec was stuck at 0.53.7 while the
  changelog tracked v0.78; `scripts/bump-version.mjs` now also syncs
  `packages/termex_shared/lib/app_version.dart` (`kAppVersion`), which the
  updater compares against the appcast — it had been frozen at 0.49.0.
- **B-3 linux-rpm artefact restored**: `release.yml` build matrix gains the
  `linux-rpm` distributor job that `distribute_options.yaml` already defined.

### Added (v0.79.x during RC hardening)

- AI settings: user-managed provider list with "+ Add Provider" dropdown;
  only configured providers appear in the AI panel switcher.
- PC sidebar per-category section header with "+" add button (parity with
  the mobile `_TerminalTabHeader` pattern) for servers / proxies / snippets.
- **i18n debt cleared**: migrated ~283 hardcoded Chinese strings across 39
  feature files to the ARB system (1148 → 1433 keys, zh/en symmetric). Only
  `ai/provider/provider_registry.dart` deferred (const list, no BuildContext).
  Also fixed the CI ARB-completeness check that pointed at a dead
  `app/lib/l10n/` path.

### Fixed (SSH connect + sidebar)

- **Password auth now falls back to keyboard-interactive.** `auth_password`
  (`crates/termex-core/src/ssh/auth.rs`) tried only the plain `password` SSH
  method. Many OpenSSH servers advertise only `keyboard-interactive`
  (`KbdInteractiveAuthentication yes`, the default on most distros), so a
  new node would fail to connect *and* fail the "Test connection" check even
  with correct credentials — the classic "works in `ssh` but not in the
  library" symptom. Now tries `password` first, then keyboard-interactive
  feeding the same password into each prompt.
- **Sidebar blank-area right-click menu.** Right-clicking empty space in the
  server tree previously did nothing. It now opens a root context menu with
  New Connection / New Group / Import SSH config, matching the legacy Tauri
  sidebar. (A server row's own right-click menu still wins on rows.)

### Fixed (GitHub issues)

- **#24 SFTP chmod / chown now functional.** The core `SftpHandle::chmod`
  was a stub returning "russh-sftp API limitation" — but russh-sftp 2.1.1
  exposes `set_metadata` (SSH_FXP_SETSTAT). Wired chmod to a real setstat
  carrying the permission bits, added a new `chown` (numeric uid/gid), a new
  `sftp_chown` FRB binding, and extended the chmod dialog with owner (UID) /
  group (GID) fields. File permissions & ownership are now editable, not
  display-only.
- **#23 ProxyCommand helper on Windows now launches hidden.** The helper
  spawn added `CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP` creation flags so
  no console window pops up. (The companion defect — orphaned helper after
  disconnect — was already handled by the `CommandStream` RAII `kill_on_drop`
  + `Drop` teardown, killed per-session.)
- **#2 Offline Windows install no longer needs WebView2.** Resolved
  structurally by the Flutter migration: the desktop app renders with its own
  engine and has zero WebView dependency, so air-gapped Windows machines can
  install without downloading the Edge WebView2 runtime.
- **#25 SFTP download extension-rewrite not reproducible in Flutter.** The
  dual-pane SFTP downloads using the remote filename verbatim (`entry.name`)
  with no OS "Save as" dialog or type filter, so no code path can rewrite
  `.log` → `.html`. The original report was almost certainly a Windows
  file-association display artifact.

## [0.78.0] — PC Cutover (Tauri build stopped)

### Deprecated / Removed (build infrastructure only — no source deletion)

- 🪦 **Tauri/Vue desktop CI build stopped.** Phase 3 of the v0.70 retirement plan brought forward from v0.75 to v0.78 because Flutter functional parity was reached early in v0.77.0.
  - `Cargo.toml` workspace no longer includes `src-tauri/`; `cargo build/test --workspace` skips it.
  - `.github/workflows/ci.yml` removes the 3 Tauri jobs; new pipeline = flutter-analyze + flutter-test + cargo workspace test + iOS/Android bootstrap + FRB drift check.
  - `.github/workflows/release.yml` rewritten around `flutter_distributor` driven by `app/distribute_options.yaml`. Artefacts: dmg / msix / deb / rpm / AppImage.
  - `package.json` scripts `dev/build/preview/lint/test/tauri` all stub to `exit 1` with deprecation message.
  - `scripts/bump-version.mjs` no longer syncs `src-tauri/tauri.conf.json` or `src-tauri/Cargo.toml`.
  - `scripts/sign-macos.sh` `APP` and `ENTITLEMENTS` paths point to `app/macos/Runner/...`.
  - `scripts/generate-icons.mjs` gains `existsSync` guard for v0.80 hit.
- **Not removed**: `src-tauri/` and `src/` directory contents stay in the repo. Physical deletion in v0.80.0.

### Added

- `scripts/legacy/build-tauri.sh` — manual rebuild recipe (debug/release/notarize modes) for forensic / rollback. Detects missing src-tauri and explains git checkout path.
- `docs/iterations/v0.78.0-pc-cutover.md` — full Phase 3 plan.
- `docs/iterations/v0.77.0-stage-3-checklist.md` — 14-section A/B walkthrough with 6-platform signature.
- `docs/MIGRATION.md` v0.78 chapter — user-impact-per-channel matrix + developer impact.

### Changed

- `README.md` v0.78 banner + commands table Flutter-first + setup split into "Production (Flutter)" / "Legacy (forensic only)".
- `docs/iterations/v0.70.0-pc-tauri-retirement.md` — Phase 3 marked v0.78 (early-completion); v0.77 parity row added.
- `packages/termex_shared/lib/system/tauri_retirement_banner.dart` — text refreshed.

### Validation

- `cargo check --workspace`: 3 crates clean.
- `flutter analyze`: 0 / 0.
- `flutter test`: 672 / 672.
- `pnpm tauri`: exit 1 with deprecation banner confirmed.

---

## [Unreleased — v0.77.0] — PC Final Parity & A/B Verification

### Added — visible parity restoration (15 V-tagged items)

- V-1 Snippet RenderFlex overflow fix; V-2 Recording + Cloud sidebar entries restored; V-3 default theme follows OS; V-6 Local PTY hides sub-tab bar; V-7 terminal pinned-dark palette; V-8 tab bar transparent border + glued `[+]` card; V-9 AI conversation list float overlay; V-10 settings polish (28 px search, sidebar 140 px, dedup header, audit overflow fix); V-11 Add Proxy password + chip protocol; V-12 AI footer dedup + dropdown overflow; V-13 provider dropdown crash + settings search tab names; V-14 Rust same-PID lock for hot restart; V-15 11 AI providers (Claude/OpenAI/Gemini/Ollama/Local AI/DeepSeek/Grok/Mistral/GLM/MiniMax/Doubao) + inline-accordion AI tab; V-17 Local AI download progress wired (DashMap + FRB poll + 250 ms Dart Timer).

### Added — P0 implementations

- Monitor Panel (info bar + 2×2 metric grid + process list + start/stop, OSS data 0 + banner pointing to commercial integration).
- AuditDashboard (5 KPI cards + filter bar + paginated table + row dialog).
- Update Dialog (4 states: checking / upToDate / available / error + scrollable release notes).
- Team UI replacing Pro stub: toolbar + sync conflicts + member list + invite dialog + passphrase verify.

### Added — P1 polish

- Tray icon via `tray_manager` with macOS/Windows/Linux support.
- Privacy tab visual alignment (`showConfirmDialog` for clears + `showTermexDialog` for GDPR + Toast).
- Server badges P / B / T capsules + Share-to-team context menu (`team_share_server` / `team_unshare_server` FRB).

### Infrastructure

- `scripts/parity-launch.sh` + `TERMEX_AUDIT_MODE` `--dart-define` enables Flutter app to use `~/.termex-flutter-audit/` so it runs side-by-side with legacy Tauri for A/B verification.

### Decisions

- P0-5 i18n (~997 hardcoded ZH strings) deferred to v0.78+ — OSS ZH users unaffected; EN-switch becomes increment.

### Validation

- `flutter analyze` 0 / 0 (fixed pre-existing `_StubServerNotifier.createServer` mismatch).
- `flutter test` 672 / 672.
- `cargo test --workspace` 132 tests / 20 crates.

---

## [Unreleased — v0.69.0] — Restructure Stabilization + Tauri Retirement Announcement

### Deprecated

- 🪦 **Tauri/Vue desktop stack enters formal retirement.** A 4-phase plan over the next 24 months drives the legacy stack to physical removal at v0.80:
  - **v0.69** (this release) — Deprecation announcement: in-app banner + MIGRATION.md chapter
  - **v0.70** — Default installs switch to Flutter; AppCast critical update nudges existing Tauri users
  - **v0.75** — CI stops building Tauri release artifacts
  - **v0.80** — `src-tauri/` and `src/` (Vue) directories physically deleted
- New feature development happens exclusively in the Flutter stack (`packages/termex_shared/` + `app/` + `termex-mobile/`). The Tauri stack accepts critical security PRs only.

### Added

- `packages/termex_shared/lib/system/tauri_retirement_banner.dart` — in-app deprecation widget (`TauriRetirementBanner` inline + `showTauriRetirementDialog` modal). Banner is dismissible via SharedPreferences `termex.tauri_retire_dismissed` so it appears at most once per install.
- `docs/MIGRATION.md` — new chapter "v0.69 起：从 Tauri 桌面切换到 Flutter 桌面" with 4-phase timeline table, data-compatibility matrix (all 5 categories share zero-migration), known behavior differences, and rollback path to stable-legacy channel.
- `docs/iterations/v0.70.0-pc-tauri-retirement.md` — full retirement plan with phase deliverables, risk/mitigation matrix, and 5 user-confirmable decision points.
- `docs/iterations/v0.69.0-pc-restructure-stabilization.md` — restructure stabilization record covering the desktop/mobile package split, build-blocker fix runbook, and i18n batch survival audit.

### Changed

- `README.md` top banner — updated from "dual-stack migration period" to explicit retirement announcement with link to MIGRATION.md §v0.69.
- `src-tauri/README.md` + `src/README.md` — retirement banners promoted from "Deprecated" to "🪦 退役进行中 (4 阶段 → v0.80)" with phase timeline inline.
- `docs/architecture.md` — top-level retirement banner; "一句话定位" updated to "Tauri/Vue (老栈，退役中) 与 Flutter (新栈，生产主推)".
- `CLAUDE.md` Repository state — updated to reflect v0.68.0 functional parity completion; new explicit "for new feature development, write Flutter only" guidance.
- Repository structure split into three top-level packages:
  - `app/` — desktop PC shell only
  - `termex-mobile/app/` — iOS/Android shell (new)
  - `packages/termex_shared/` — cross-platform shared business logic and widgets
- `flutter analyze` baseline restored to 0 errors after structural cleanup (was 201 pre-restructure).

### Fixed

- Stabilized 14 broken cross-package imports in `packages/termex_shared/lib/widgets/*.dart` (`package:termex/design/tokens.dart` → `package:termex_shared/design/tokens.dart`).
- Migrated entire `features/team/` directory (20 files) from `app/lib/` to `packages/termex_shared/lib/features/team/` (subsequently relocated again during the desktop/mobile split — see v0.69 restructure doc §6).
- Restored macOS release build (was failing at Dart kernel snapshot with missing `MonitorPanel` + `showTeamPassphraseDialog` references after the second-wave restructure deleted those modules). Minimal stubs in `tab_workspace.dart` and `team_tab.dart` keep the build green until the team/cloud/monitor features land in their final package locations.
- `crates/termex-core/src/lib.rs` — added missing `pub mod sync;` registration that was blocking aarch64-apple-darwin Cargo target builds.
- `about_tab_test.dart` — added `localizationsDelegates` + `Locale('zh')` to test `MaterialApp` so post-i18n migration assertions resolve correctly; updated `find.text('已是最新版本')` to `find.textContaining(...)` to match the `updateUpToDate` ARB value (`'已是最新版本！'` with punctuation).

### Internationalization (i18n)

- ARB key set grew from 804 → **997 keys** (zh + en, +193 keys this iteration).
- Eight high-impact widget files completed full i18n migration with `AppLocalizations.of(context)`:
  - `about_tab.dart` (21 strings → 0)
  - `settings_page.dart` (29 → 0, including `kSettingsIndex` const list → `buildSettingsIndex(l)` builder)
  - `backup_tab.dart` (20 → 0)
  - `privacy_policy_dialog.dart` (30 → 0)
  - `proxies_tab.dart` (22 → 0)
  - `git_sync_panel.dart` (20 → 0)
  - `file_list.dart` (19 → 0)
- One file (`cloud_panel.dart`, 22 strings) was lost in the second-wave restructure and will be re-migrated when the cloud panel reappears in its new package location.

---

## [Unreleased — v0.52.0] — Gap Coverage

### Added

- **Rust backend depth for Flutter bridge**
  - `crates/termex-flutter-bridge/src/api/local_ai.rs` — wired `local_ai_start` / `local_ai_stop` to `termex_core::local_ai::LlamaServerState` with auto port allocation (15000–16000), orphan process reclamation, PID file tracking.
  - `local_ai_download_model` — HTTP Range-aware download via `termex_core::local_ai::downloader` with SHA256 verification and primary→mirror URL fallback.
  - `local_ai_cancel_download` — now sends on oneshot channel tracked in `ACTIVE_DOWNLOADS` DashMap.
  - `local_ai_auto_start_is_cancelled` / `local_ai_auto_start_reset` — atomic-flag based auto-start cancellation for Flutter's launch coroutine.
  - `termex_core::ai::provider_client` — new module with real HTTP client for Claude, OpenAI-compatible, Ollama, Gemini, and local llama-server. Supports both single-shot completion and SSE streaming.
  - `ai_verify_api_key` / `ai_test_provider_config` — real verification via minimal completion call.
  - `ai_explain_command` / `ai_diagnose_error` / `ai_nl2cmd` / `ai_autocomplete` — wired to `provider_client::complete` with proper prompt construction and context redaction.
  - `ai_send_message` / `poll_ai_chunks` / `ai_cancel_generation` — streaming generation via detached tokio task + per-conversation chunk queue polled by Dart.
  - `ai_extract_commands` — now uses `regex::Regex` for inline code extraction alongside fenced block parsing.
- **Team CRUD wiring**
  - Migration V24: `team_members` + `team_invites` tables.
  - `team_add_member` — new bridge helper for invite-accept + tests.
  - `team_get_members` / `team_remove_member` / `team_update_role` — real SQL queries, owner-protection and last-owner check enforced.
  - `team_invite_accept` — decodes + verifies signature/expiry, verifies passphrase against keychain, inserts caller as member, marks invite row as accepted.
  - `team_sync_now` — graceful no-op when no team_repo_path configured; records sync attempt timestamp; counts new pending conflicts.
- **Cross-platform disk space check**
  - `termex_core::local_ai::storage::get_available_space` — now uses the `fs2` crate for cross-platform `available_space`, walks up parent chain for missing paths.
- **FRB codegen resilience**
  - Tagged `as_str` / `from_str` / internal conversion methods with `#[flutter_rust_bridge::frb(ignore)]` so codegen no longer emits broken `RustAutoOpaqueInner<str>` bindings. Bridge now compiles cleanly against `flutter_rust_bridge = 2.12`.

### Changed

- `port_forward_find_conflict` / `port_forward_suggest_free_port` — signatures now take `String` instead of `&str` (FRB compatibility).
- Tauri storage tests updated for V24 migration count (24 total).
- Existing AI and team tests updated to assert against the new real-HTTP / real-DB behavior (see `tests/test_api_ai.rs`, `tests/test_api_team.rs`, new `tests/test_api_team_v2.rs`).

### Still pending in v0.52.0 (see [`docs/iterations/v0.52.0-gap-coverage.md`](docs/iterations/v0.52.0-gap-coverage.md))

- Version bump 0.34.0 → 0.52.0 (reserved for user-driven action per project convention).
- Release cutover: signing certificate config, first end-to-end `scripts/release.sh` dry-run, CHANGELOG promotion from `Unreleased`.
- Feature hardening: team multi-user conflict E2E test, cloud credential E2E, window state persistence lifecycle test, formal a11y walk, performance benchmark values.
- Plugin system runtime (WASM vs. scripted).

---

## [0.34.0] — 2026-02-XX

See `docs/iterations/v0.34.0-team-collaboration-v2.md`.

- Team collaboration v2: conflict resolution UI, CRDT merge of servers/snippets/proxies/recordings/cloud favorites.
- Proxy Tor binary bundled.

## [0.33.0] — Cloud Native

Cloud integration (K8s, AWS SSM, Aliyun) with shared favorites and team-aware resource permissions.

## [0.32.0] — Terminal Split Pane

## [0.31.0] — AI Assistant Evolution

## [0.30.1] — Local AI Auto-Start

Local AI engine management: top bar indicator, one-click start, AI panel progress, health check. See [`docs/iterations/v0.30.1-local-ai-auto-start.md`](docs/iterations/v0.30.1-local-ai-auto-start.md).

## [0.30.0] — Team Collaboration v1

Initial team sync via Git remotes, passphrase-encrypted workspace blobs.

## [0.29.0] — Session Recording

asciicast v2 recording + player, searchable history, auto-record toggle.

## [0.28.0] — Server Monitoring

Real-time CPU / memory / network / disk / load graphs via sshtop.

## [0.27.0] — SSH Config + Snippets

Parse & import `~/.ssh/config`; snippet library with variable interpolation and usage tracking.

## [0.26.0] — AI Smart Autocomplete

Prefix trie + AI fallback for terminal autocomplete with 4-char threshold.

## [0.25.0] — Security + Compliance

Audit log, GDPR erase-all, export/import with independent password.

## [0.24.0] — Connection Chain

## [0.23.0] — Portable Mode

## [0.22.0] — Proxy Command + Cloudflare Access

## [0.21.0] — Dynamic Forward

## [0.20.0] — Tor + Tmux + Git

## [0.19.0] — SFTP Per-Tab

## [0.18.0] — Proxy Protocols

## [0.17.0] — Server-to-Server SFTP

## [0.16.0] — Custom Keybindings

## [0.15.0] — Terminal Search

## [0.14.0] — Font Management

## [0.13.0] — SFTP Enhancement

## [0.12.0] — ProxyJump / Bastion

## [0.11.0] — Local AI (complete)

## [0.10.0] — Keychain Security

## [0.9.0] — Stable Release

## [0.8.0] — Plugin System (v1, UI only)

## [0.7.0] — Recording + Monitoring Foundations

## [0.6.0] — AI Advanced

## [0.5.0] — AI Core

## [0.4.0] — Theme + UX

## [0.3.0] — Port Forwarding

## [0.2.0] — SFTP

## [0.1.0] — MVP

Initial release: SSH password/key auth, VT100 terminal, multi-tab, SQLCipher encryption.

---

## Flutter Migration Appendix (v0.40.0–v0.51.6)

The 12 iterations v0.40.0 → v0.51.6 shipped the Flutter rewrite's foundation without cutting a user-facing release on their own version numbers. Their deliverables are rolled into **v0.52.0** (this entry).

- **v0.40.0 – v0.44.0**: Flutter shell + terminal emulator + UI design system + server management + SFTP. See status banners atop `docs/iterations/v0.40.0-flutter-foundation.md` etc.
- **v0.45.0 – v0.47.0**: AI panel, settings/team/cloud, monitor/recording.
- **v0.48.0**: Performance benchmarks (`app/benchmark/`), shortcut registry (`app/lib/shortcuts/`), window state persistence, i18n (en/zh arb).
- **v0.49.0**: Release pipeline infrastructure (`distribute_options.yaml`, platform sign scripts, auto-updater stubs, flutter-release CI).
- **v0.50.0**: Anti-AI sentinel in Rust + Dart.
- **v0.51.0 – v0.51.6**: Remediation — FRB first codegen, 71 TODO → 0, Flutter test 497/0/0.

See [`docs/iterations/v0.51.1-audit-appendix.md`](docs/iterations/v0.51.1-audit-appendix.md) for the historical audit snapshot taken at v0.51.0 kickoff.
