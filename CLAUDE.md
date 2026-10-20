# Termex - Claude Code Rules

> Terminal + Experience | 以 SSH 协议为底座，打造 AI 时代永不断线的云端智能工作平台

## Project Overview

Termex is an open-source, AI-native SSH client. Built on SSH as the foundation, it creates an always-on cloud AI workspace for the AI era. It targets developers and ops engineers who need a beautiful, fast, intelligent, and free SSH client.

**Repository state (v0.80.0+)**: the legacy Tauri/Vue desktop stack has been **removed**. The repo now contains a single production UI — Flutter — plus the shared Rust core.

- Flutter desktop + mobile: `app/` + `packages/termex_shared/`
- Rust core: `crates/termex-core/` + `crates/termex-flutter-bridge/` + `crates/termexd/`
- Optional commercial logic: `crates/termex-core-private/` (empty stub in OSS builds)
- New feature code goes in `packages/termex_shared/lib/` or `app/lib/`. Do not reintroduce Tauri, Vue, Electron, or any WebView-based stack.

**🛣 Two product routes** (since v0.71):
- **Desktop = Route A · Terminal-first**: full terminal + chain/proxy/forward editing + AI sidebar; deep long-form ops
- **Mobile = Route B · AI Operator Console**: monitor & react to long-running AI tasks; structured summaries primary; terminal is "advanced details" only; voice-first dispatch with safety guardrails

Mobile **retains** Route A baseline (terminal view, etc.) but never makes terminal the primary experience. See [`docs/mobile-strategy.md`](docs/mobile-strategy.md). New mobile features must map to one of the four strategic pillars (Persistent Channel / Structured Outcome / Trustworthy Execution / Network Path Parity) or be explicitly justified.

**Push channel policy**: WebSocket long-lived connection (OSS, via `termexd` daemon) is the **primary** channel — app foreground + screen-always-on (toggleable) keeps it alive. FCM (Pro) is **fallback only** for backgrounded apps. Never design features that hard-depend on FCM — OSS / self-hosted / China-region users must still get core functionality. China-region push (JPush / Xiaomi / Huawei / OPPO / vivo) is deferred to v0.75+.

## Tech Stack

- **Runtime**: Flutter 3.27+ (Dart)
- **UI**: self-drawn `Termex*` widgets under `packages/termex_shared/lib/widgets/`; design tokens under `packages/termex_shared/lib/design/`
- **App shell**: `WidgetsApp` + `TermexThemeScope` in `app/lib/main.dart` (not `MaterialApp`)
- **Terminal**: Dart `package:xterm` emulator + custom pane/split controller under `packages/termex_shared/lib/terminal/`
- **State**: Riverpod
- **Bridge**: flutter_rust_bridge v2 (`crates/termex-flutter-bridge/`)
- **Business core**: Rust in `crates/termex-core/` — russh, ring, SQLCipher, tokio
- **Remote daemon**: `crates/termexd/` (WebSocket over an SSH tunnel)
- **Database**: SQLite + SQLCipher (encrypted)

## Architecture

```
app/                          # Flutter entrypoint + platform shells
├── lib/main.dart             # WidgetsApp + theme scope
├── lib/desktop/              # Desktop shell, menus, tray, sidebar
├── lib/mobile/               # Mobile shell, notifications, task views
├── lib/cross_tab/            # Cross-tab search / broadcast
├── macos/ windows/ linux/    # Desktop platform shells
├── ios/ android/             # Mobile platform shells
├── test/ integration_test/
└── distribute_options.yaml   # flutter_distributor release config

packages/termex_shared/       # Shared Flutter UI + feature modules
├── lib/design/               # Tokens / theme / typography
├── lib/widgets/              # Self-drawn Termex* design system
├── lib/features/             # server_list, ai, sftp, team, settings, ...
├── lib/terminal/             # Terminal view + pane/split controller
├── lib/system/               # Updater, keychain, clipboard, platform glue
├── lib/l10n/                 # ARB-generated localizations
└── pubspec.yaml

crates/
├── termex-core/              # Shared Rust business logic
├── termex-flutter-bridge/    # flutter_rust_bridge v2 API surface
├── termexd/                  # Remote daemon (task state + WebSocket)
└── termex-core-private/      # Optional closed-source stub; excluded from OSS builds

flutter_rust_bridge.yaml      # FRB codegen config
scripts/frb-codegen.sh        # Regenerate Dart bindings from Rust API
```

**Key rule**: any change to the FRB API surface under `crates/termex-flutter-bridge/src/api/*.rs` requires running `./scripts/frb-codegen.sh` to keep Dart bindings in sync. CI enforces idempotency.

## Code Conventions

### Rust (`crates/termex-core/`)

- Business logic lives in dedicated modules (`ssh/`, `crypto/`, `ai/`, `storage/`, ...), **not** in the bridge layer
- The bridge (`crates/termex-flutter-bridge/src/api/`) is a thin adapter: validate input → call core → return result
- Use `thiserror` for error types, map to `String` at the bridge boundary
- All async operations use `tokio`
- Never log passwords, API keys, or any sensitive data
- Use `uuid::Uuid::new_v4()` for all IDs
- Database timestamps use ISO 8601 format (`chrono::Utc::now().to_rfc3339()`)
- Encrypted fields (passwords, API keys) use the `_enc` suffix and store as `BLOB`
- All public functions must have doc comments
- No `unwrap()` in production code — use `?` or proper error handling

### Dart / Flutter (`app/`, `packages/termex_shared/`)

- Self-drawn widgets first: use `packages/termex_shared/lib/widgets/` and `design/tokens.dart` before raw Material widgets
- Material is a low-level primitive only (`showDialog`, `SnackBar`, text editing overlays). Do not add `AppBar` / `Drawer` / `MaterialApp`-based navigation
- Feature code lives in `packages/termex_shared/lib/features/<feature>/`, split into `state/` + `widgets/` when a file grows
- Use Riverpod for state; no global mutable singletons for feature state
- All user-facing text goes through `AppLocalizations` (ARB); no hardcoded strings
- Use `dart format`; keep files under the 800-line limit

### General

- Commit messages: `<type>(<scope>): <description>` (e.g., `feat(ssh): add RSA key authentication`)
- Types: feat, fix, refactor, style, docs, test, chore
- Scopes: ssh, sftp, ui, ai, crypto, storage, config, bridge, mobile
- No `any` / unchecked dynamic types — define proper Dart types or Rust DTOs
- **单文件行数上限 800 行** — 超过时必须按职责拆分为多个文件。Rust 用 `mod` 子模块拆分，Dart 按 feature/widget/state 拆分。宁可多文件也不要单文件臃肿
- **实现与测试必须同步** — 每个功能模块在实现的同时必须编写对应的单元测试/集成测试。不允许先实现后补测试，也不允许提交无测试覆盖的功能代码
- **测试代码独立存放** — 所有测试用例必须放在独立的 `tests/` 目录下，按模块分类组织，禁止在业务代码文件内编写 `#[cfg(test)] mod tests`。Rust 测试放在 `crates/*/tests/`，Flutter 测试放在 `app/test/` 或 `packages/termex_shared/test/`

## Security Rules (CRITICAL)

- **NEVER** log sensitive data (passwords, keys, tokens) at any log level
- **NEVER** send credentials to AI providers — only send command text and server metadata (OS, hostname)
- **NEVER** include secrets in error messages returned to the frontend

### Credential Storage Strategy (v0.10.0+)

- **Primary: OS Keychain** — SSH passwords, passphrases, AI API keys stored via `keyring` crate
  - macOS: Keychain Services (Secure Enclave)
  - Windows: Credential Manager (DPAPI)
  - Linux: Secret Service (GNOME Keyring / KDE Wallet)
- **termex.db stores only keychain reference IDs** (e.g., `termex:ssh:password:{uuid}`), never actual credentials
- **Fallback: AES-256-GCM + Master Password** — when OS keychain is unavailable (headless Linux)
  - Encryption uses `ring` crate with AES-256-GCM
  - Key derivation uses Argon2id (m=64MB, t=3, p=4)
  - Master key exists only in memory, zeroed on app lock
- Export files use independent password + salt, decoupled from keychain/master password

### Keychain Single-Prompt Rule (CRITICAL)

- **OS keychain 每次启动最多弹出 1 次密码提示** — 这是硬性要求，违反会严重影响用户体验
- 所有凭据存储在**单一 keychain entry** (`__termex_store__`) 中，以 JSON 对象形式存储
- **只有 `init()` 可以调用 `get_password()`**（读取 OS keychain）
- **只有 `flush()` 可以调用 `set_password()`**（写入 OS keychain）
- **其他任何函数禁止直接访问 `keyring::Entry`** — 一律通过内存缓存 `get()`/`store()`
- 禁止创建额外的 keychain entry（无 per-server、per-provider、verification token 条目）
- `verify_accessible()` 仅检查 `is_available()` 返回值，不执行额外的 keychain 读取

## Bridge Conventions

- Rust API surface: `crates/termex-flutter-bridge/src/api/<module>.rs`
- Dart entrypoint: `crates/termex-flutter-bridge/lib/api.dart` (generated)
- All bridge functions return `Result<T, String>`-shaped values; errors are converted at the boundary
- Streaming terminal/SFTP data uses the bridge's event/poll streams — never one FFI call per byte
- After any FRB API change: `./scripts/frb-codegen.sh` (and commit the regenerated files)

## Testing

- Rust: `cargo test --workspace` for unit + integration tests
- Flutter: `cd app && flutter test`; shared package tests live in `packages/termex_shared/test/`
- Integration: `cd app && flutter test integration_test/`
- Crypto module must have comprehensive test coverage
- SSH tests use mock server where possible
- **每次迭代/修改必须确保所有测试用例通过** — 修改结构体字段、新增 migration、改变函数签名等操作后，必须同步更新对应的测试断言值（如 migration 数量、结构体初始化字段）。CI 中测试不通过会阻止发布
- CI 使用 `cargo test --workspace --release` 运行测试，确保与生产构建行为一致

## Performance Guidelines

- Startup time target: < 2 seconds
- Terminal input latency: < 16ms (60fps)
- Memory per session: < 100MB
- Support 20+ simultaneous tabs
- Terminal rendering uses Flutter's raster pipeline; avoid rebuilding whole panes on every byte
- Lazy-load settings panels and SFTP panel
- Debounce search input (300ms)
- SSH data events: batch small writes, don't emit per-byte

## File Naming

- Rust: snake_case for files and modules (`port_forward.rs`)
- Dart: snake_case for files (`server_list_page.dart`), PascalCase for classes/widgets
- Database: snake_case for tables and columns (`auth_type`, `created_at`)
- Tests: `test_<module>.rs` for Rust, `<feature>_test.dart` for Flutter

## Key Design Decisions

1. **Flutter over WebView/Tauri**: one UI codebase for desktop + mobile, no embedded browser, native rendering
2. **SQLCipher over plain SQLite**: all user data is encrypted at rest
3. **russh over ssh2-rs**: pure Rust, no C dependency, better async support
4. **Riverpod over global state**: testable, composable state for desktop + mobile
5. **ring over RustCrypto**: more battle-tested, used by major projects
6. **Argon2id over PBKDF2**: stronger against GPU/ASIC attacks for KDF
7. **ffi over IPC**: flutter_rust_bridge keeps the Rust core shared by every platform
8. **Multi-provider AI**: abstract trait allows plugging any LLM backend
9. **User brings own key**: no proxy server, no Termex backend, pure local app

## Common Commands

```bash
# Rust workspace (termex-core + termex-flutter-bridge + termexd)
cargo test --workspace
cargo test --workspace --release
cargo clippy --workspace

# FRB codegen
./scripts/frb-codegen.sh             # regenerate Dart bindings
./scripts/frb-codegen.sh --check     # CI drift check

# Flutter
cd app && flutter pub get
cd app && flutter analyze
cd app && flutter test
cd app && flutter test integration_test/
cd app && flutter run -d macos       # or -d windows / -d linux
cd app && flutter build macos --release

# Version bump (Node built-in; no npm dependencies)
node scripts/bump-version.mjs patch  # 0.80.0 → 0.80.1
node scripts/bump-version.mjs minor  # 0.80.0 → 0.81.0
```

### Version Bump

`node scripts/bump-version.mjs <patch|minor|major|x.y.z>` syncs:
- `package.json`
- `crates/termex-core/Cargo.toml`
- `crates/termex-flutter-bridge/Cargo.toml`
- `app/pubspec.yaml`
- `packages/termex_shared/lib/app_version.dart`

`termexd` is versioned independently (its release workflow is tag-driven:
`termexd-v*`), so it is intentionally not part of this bump.

## Documentation

- `README.md` — product overview, setup, commands
- `docs/requirements.md` — product requirements (historical; Vue/Tauri-era sections may be outdated)
- `docs/detailed-design.md` — architecture / DB schema (historical; Vue/Tauri-era examples)
- `docs/architecture.md` — current Flutter + Rust architecture
- `docs/mobile-strategy.md` — Route B product strategy
- `docs/tech-debt.md` — known debt
- `docs/MIGRATION.md` — historical Tauri → Flutter migration guide

### Iteration document naming (docs/iterations/)

All files under `docs/iterations/` MUST follow this format:

```
v{版本号}-{scope}-{迭代版本文档名称}.md
```

Where `{scope}` is exactly one of:

| Scope     | When to use                                                                 |
|-----------|------------------------------------------------------------------------------|
| `pc`      | Desktop client work — Flutter desktop UI, packaging                         |
| `mobile`  | iOS / Android Flutter app — UI, navigation, mobile-only features            |
| `web`     | Future browser/web client                                                   |
| `core`    | `crates/termex-core` business logic — SSH/SFTP/crypto/keychain/AI/team etc. |
| `bridge`  | `crates/termex-flutter-bridge` — FRB wiring, codegen, Rust↔Dart contract    |
| `homebrew`| Homebrew formula / tap maintenance                                          |

## What NOT to Do

- Do not reintroduce Tauri, Vue, Electron, or any WebView/web-based runtime
- Do not create a backend server / SaaS component — this is a pure local app
- Do not add telemetry or analytics without explicit user consent
- Do not bypass SQLCipher encryption for "convenience"
- Do not store master password anywhere — it must be entered each session
- Do not make AI features mandatory — they must work with AI disabled
- Do not break cross-platform compatibility (test on Mac, Windows, Linux)
