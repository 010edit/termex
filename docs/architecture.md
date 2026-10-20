# Termex 架构总览

> 本文档解释 Termex monorepo 的目录结构与运行时架构，作为新成员/AI 助手的快速入门参考。
>
> **v0.80.0**：Tauri/Vue 桌面老栈已物理删除。当前生产栈只有 Flutter（桌面 + 移动）+ Rust core。

## 一句话定位

**Termex 是 Flutter（桌面 + 移动）与 Rust core 组成的 SSH 客户端**。所有业务逻辑统一沉淀在 `crates/termex-core/`，通过 `flutter_rust_bridge` v2 以 FFI 方式暴露给 Dart；不包含 WebView、Electron 或 Node.js 运行时。

## 顶层目录映射

```
termex/
│
├── ─── 业务核心层（唯一权威）─────────────────────────────────
├── crates/
│   ├── termex-core/             # 业务逻辑：ssh/sftp/crypto/storage/ai/team/monitor/recording
│   ├── termex-flutter-bridge/   # flutter_rust_bridge v2 绑定层（不写业务，只暴露 API）
│   ├── termexd/                 # 远端守护进程：任务状态 + WebSocket（SSH 隧道内）
│   └── termex-core-private/     # 闭源商业逻辑的可选 stub（OSS 构建不编译）
│
├── ─── UI 层：Flutter ────────────────────────────────────────
├── packages/termex_shared/      # 桌面 + 移动共享的 Dart 代码
│   ├── lib/design/              # Token / Theme / Typography
│   ├── lib/widgets/             # 自绘 Termex* 设计系统组件
│   ├── lib/features/            # 业务模块（server_list/ai/sftp/team/settings...）
│   ├── lib/terminal/            # 终端视图 + pane/split 控制器
│   ├── lib/system/              # 更新、keychain、剪贴板、平台适配
│   └── lib/l10n/                # ARB 生成的本地化
│
├── app/                         # Flutter 应用入口 + 平台壳
│   ├── lib/main.dart            # WidgetsApp + TermexThemeScope
│   ├── lib/desktop/             # 桌面 shell / 菜单 / 托盘 / 侧栏
│   ├── lib/mobile/              # 移动 shell / 通知 / 任务视图
│   ├── macos/ windows/ linux/   # 桌面平台工程
│   ├── ios/ android/            # 移动平台工程
│   └── test/ integration_test/
│
├── ─── 工程辅助 ──────────────────────────────────────────────
├── docs/                        # 架构 / 产品 / 历史迁移文档
├── scripts/                     # frb-codegen.sh / bump-version.mjs / 签名
├── Cargo.toml                   # Rust workspace 根
├── package.json                 # 仅保留 version:bump（无 npm 依赖）
├── flutter_rust_bridge.yaml     # FRB codegen 配置
└── CLAUDE.md                    # AI 助手指令
```

## 数据通路

```
                    ┌──────────────────────────────┐
                    │  crates/termex-core (Rust)   │
                    │  业务逻辑 / 加密 / 存储 / SSH  │
                    └─────────────┬────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │  termex-flutter-bridge     │
                    │  flutter_rust_bridge v2 FFI │
                    └─────────────┬─────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │  packages/termex_shared    │
                    │  Dart UI / features / state│
                    └─────────────┬─────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
   ┌─────────────────────┐            ┌──────────────────────────────┐
   │   app/lib/desktop   │            │       app/lib/mobile         │
   │   macOS/Win/Linux   │            │       iOS / Android          │
   └─────────────────────┘            └──────────────────────────────┘
```

远端长任务另有一条通路：客户端通过 SSH 隧道连接 `termexd` 的 WebSocket
（默认 `127.0.0.1:7821`，Bearer token 鉴权），由 `termexd` 持有任务状态并
拉起 AI CLI 子进程。

## 关键目录职责

| 目录 | 职责 | 不该放什么 |
|---|---|---|
| `crates/termex-core/` | 所有业务逻辑、加密、数据库、SSH/SFTP、AI provider | UI、平台窗口、Flutter 类型 |
| `crates/termex-flutter-bridge/src/api/` | 参数校验、DTO、调用 core | 业务规则、直接 SQL |
| `packages/termex_shared/lib/features/` | 可复用 UI + Riverpod 状态 | 平台专属窗口代码 |
| `app/lib/desktop/` / `app/lib/mobile/` | 平台 shell、导航、菜单、托盘 | 可跨端复用的业务 UI |
| `packages/termex_shared/lib/design/` + `widgets/` | 设计 token + 自绘组件 | 业务状态 |

## 核心约定（CLAUDE.md 摘要）

- **任何 FRB API 改动**必须运行 `./scripts/frb-codegen.sh` 同步 Dart 绑定
- **业务逻辑只能写在 [../crates/termex-core/](../crates/termex-core/)**，bridge 与 Dart 层都是适配层
- **单文件 ≤ 800 行**，超过必须拆分
- **测试与实现同步提交**，禁止后补
- **Rust 测试放 `crates/*/tests/`**，禁止内嵌 `#[cfg(test)] mod tests`
- **Keychain 启动最多弹 1 次**（详见 CLAUDE.md "Keychain Single-Prompt Rule"）

## 何时该读哪个文档

| 想了解 | 读 |
|---|---|
| 项目愿景 / 商业定位 | [../README.md](../README.md) |
| 编码规范 / 安全规则 / 命令 | [../CLAUDE.md](../CLAUDE.md) |
| 移动端产品策略 | [mobile-strategy.md](mobile-strategy.md) |
| 历史迁移过程（Tauri → Flutter） | [MIGRATION.md](MIGRATION.md) / [migration/](migration/) |
| 历史决策与债务 | [tech-debt.md](tech-debt.md) |
| 当前迭代 | `docs/iterations/`（本地维护，默认在 `.gitignore`） |
