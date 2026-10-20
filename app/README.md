# Termex — Flutter App

This is the production Flutter UI for Termex (desktop + mobile). The legacy
Tauri/Vue stack was removed in v0.80.0; all platform shells now live here and
in [`packages/termex_shared/`](../packages/termex_shared/).

See [../README.md](../README.md) for product overview and
[../CLAUDE.md](../CLAUDE.md) for coding conventions.

---

## Prerequisites

- **Rust** (stable, via [rustup](https://rustup.rs/))
- **Flutter SDK** 3.27+ ([install guide](https://docs.flutter.dev/get-started/install))
- **flutter_rust_bridge codegen**, exact pin:
  ```bash
  cargo install flutter_rust_bridge_codegen --version '=2.12.0'
  ```

Verify your setup:
```bash
flutter --version                        # should show 3.27+
flutter doctor                           # address any red items
flutter_rust_bridge_codegen --version    # should show 2.12.0
```

> The Dart runtime is pinned to `flutter_rust_bridge: 2.12.0` in
> `pubspec.yaml`. Using a newer codegen rewrites the generated-file headers
> and fails the CI drift check.

---

## Setup (first time)

```bash
cd ..                              # repo root
./scripts/frb-codegen.sh           # generate Dart bindings from crates/termex-flutter-bridge/src/api/
cd app
flutter pub get                    # resolve Dart dependencies
```

The generated bindings are checked into git. Without running codegen after a
Rust API change, the app still compiles but the FRB drift check will fail.

---

## Run

```bash
flutter run -d macos               # macOS
flutter run -d windows             # Windows
flutter run -d linux               # Linux
flutter run -d "iPhone 17 Pro"     # iOS simulator
flutter run -d emulator-5554       # Android
```

Hot reload is fully supported for Dart. Changes to Rust require a rebuild:

```bash
cargo build --release -p termex_flutter_bridge
flutter run -d macos               # or restart the running instance with `R`
```

---

## Build

```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
flutter build ios --release --no-codesign
flutter build apk --release
```

Signed desktop installers are produced by the tag-driven
[release workflow](../.github/workflows/release.yml). The
[desktop build workflow](../.github/workflows/build-desktop.yml) produces
unsigned Linux/Windows bundles on push and pull request.

---

## Directory map

```
app/lib/
├── main.dart                 # WidgetsApp + TermexThemeScope + boot
├── desktop/                  # Desktop shell, menus, tray, sidebar, status bar
├── mobile/                   # Mobile shell, notifications, task views
├── cross_tab/                # Cross-tab search / broadcast
└── ...

packages/termex_shared/lib/
├── design/                   # Tokens / theme / typography
├── widgets/                  # Self-drawn Termex* components
├── features/                 # Feature modules (server_list, ai, sftp, team, ...)
├── terminal/                 # Terminal view + pane/split controller
├── system/                   # Updater, keychain, clipboard, platform glue
└── l10n/                     # ARB-generated localizations

crates/termex-flutter-bridge/
├── src/api/                  # FRB API surface (Rust)
├── lib/src/generated/        # Generated Dart bindings
└── src/frb_generated.rs      # Generated Rust glue
```

Platform shells live in `app/macos/`, `app/windows/`, `app/linux/`,
`app/ios/`, and `app/android/`.

---

## Tests

```bash
cd app && flutter test
cd app && flutter test integration_test/
```
