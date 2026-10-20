# Termex Flutter + Rust 架构迁移路线图 (v0.40.0 – v0.49.0)

> **历史文档**：迁移已完成，Tauri/Vue 老栈已于 v0.80.0 删除。
> 本文保留当时的决策背景与迁移映射，不再作为当前开发指南。

> 状态：**已完成（历史记录）**
> 起点版本：v0.39.0 (桌面端 Vue + Tauri 架构桥接版)
> 目标版本：v0.49.0 (桌面端 Flutter + Rust core 正式切换)
> 后续：v0.60.0+ (移动端重启)

---

## 一、背景与战略判断

### 1.1 现状

Termex v0.34.0 是一款成熟的桌面 SSH 客户端：
- **前端**: Vue 3.5 + Pinia 2.2 + Element Plus 2.9 + Tailwind 3.4 + xterm.js 5.5 (81 组件 / 25 composables / 14 stores)
- **后端**: Tauri 2 + russh 0.49 + SQLCipher + ring/argon2 (13 核心模块 / 195 Tauri 命令 / 347 Rust 测试)
- **平台**: macOS / Windows / Linux 三桌面平台稳定运行

### 1.2 战略驱动

2026 年初的战略重心是**向移动端扩展**，把"SSH 云端永不断线工作平台"从桌面延展到 iPhone / Android / iPad。在评估移动端实现路径时，有 4 个候选方案：

- **方案 A — Tauri v2 + Vue WebView**: 复用桌面代码，但 xterm.js 在 WebView 中有已知的性能和键盘集成问题，Tauri v2 移动端成熟度不足
- **方案 B — Swift/Kotlin 原生 + Rust core**: iOS/Android 体验最佳，但进入三套 UI 维护地狱
- **方案 C — Swift 全重写**: 放弃 Rust 核心，代价巨大不可行
- **方案 D — Flutter + Rust core**: 一套 UI 跨五平台（mac/win/linux/ios/android），通过 `flutter_rust_bridge` 复用 100% Rust 核心

### 1.3 关键决策与时间窗

**采用方案 D**。战略判断依据：

1. **沉没成本为零**: 移动端尚未启动，没有任何 Vue 移动代码需要抛弃
2. **PC 需求固化**: Vue 桌面版稳定运行 34 个迭代，功能边界清晰，这是**重写目标最明确**的时间点
3. **时间窗稍纵即逝**: 若先用方案 A 做 4 个移动迭代，再推倒重来，代价呈指数级上升

**决策引言**:
> "当前移动端还没开始没有多少资产负债，PC 端相对稳定，这时候先改 PC 端代价反而很小。"

---

## 二、架构决策（锁定）

| 维度 | 选择 | 理由 |
|------|------|------|
| **UI 框架** | Flutter (Dart) | 单一代码库覆盖 5 平台；Skia 渲染管线强，自绘性能足够 |
| **终端渲染** | 自写 VT100/xterm 内核（Dart + CustomPainter） | xterm.dart 维护活跃度不足；自写可完全掌控性能与兼容性 |
| **UI 组件** | 完全自绘，不依赖 Material / Cupertino / 第三方 kit | 跨平台视觉一致性；避免被 Material Design 风格锁死 |
| **IPC 桥接** | `flutter_rust_bridge` v2 | 最成熟的 Rust-Dart 桥，codegen 完整，支持双向 Stream |
| **状态管理** | Riverpod (Dart) | Pinia 的 Dart 等价物；Composition API 风格延续 |
| **数据库** | SQLCipher + rusqlite | 不变，继续用 Rust core |
| **打包分发** | flutter_distributor + 自写签名/自动更新流水线 | Tauri v2 updater 不复用 |
| **i18n** | Flutter intl + ARB 文件 | vue-i18n 文案移植；key 命名惯例保留 |

---

## 三、分支策略与治理政策

### 3.1 分支划分

```
main 分支 (Vue + Tauri, v0.39.0 - v0.39.x 维护版)
  │
  │   只修 bug，不加新功能
  │   每个 bug-fix commit 打标签 [backport-flutter]
  │
  └─── feature 分支 (Flutter + Rust core)
         │
         │   所有 v0.40.0 - v0.49.0 工作在此分支
         │   Rust core 解耦也在此分支（用户决策）
         │
         └─── v0.49.0 正式切换时一次性合并回 main
```

### 3.2 治理规则（长生命周期 feature 分支）

因 feature 分支预计存活 6–8 个月，必须强约束以下规则避免合并地狱：

1. **Bug 标签化**: main 分支每个 bug-fix commit 的 message 必须包含 `[backport-flutter]`，方便最终合并时一次性扫荡回填
2. **依赖月度同步**: 每月一次把 main 的 `Cargo.lock` 升级 diff 同步到 feature 分支的 `crates/*/Cargo.toml`，避免最终合并时依赖冲突累积
3. **测试基线硬条件**: feature 分支合并回 main 的**前置条件**是 Rust core (termex-core) 的全部测试保持绿色，覆盖率不降。若 feature 分支新增了 core 测试，main 最终也会继承
4. **现有 Tauri 层不动**: `crates/termex-tauri/` 在 feature 分支保持 import `termex-core` 的桌面 Vue+Tauri 版本可编译，**不引入任何破坏性变更**。这是万一方案 D 失败时的逃生通道
5. **并行发布机制**: v0.48.0 起，main 通道继续发 v0.39.x 稳定版；feature 通道开始发 v0.48.x-beta；v0.49.0 起才正式切换默认通道
6. **Bug 回填节点**: v0.49.0 合并前，一次性 cherry-pick 或重实现所有 `[backport-flutter]` 标签的 commits 到 feature 分支等价位置

### 3.3 风险揭示

本分支策略的代价：**最终合并时的 bug 回填工作可能消耗 1-2 周**，且 main 分支半年来积累的 bug 修复若在 feature 分支对应代码已重构（从 `src-tauri/src/` 到 `crates/termex-core/src/`），回填需要人工判断等价位置。

缓解手段：`[backport-flutter]` 标签 + 模块路径映射文档 (见 v0.40.0 §4)。

---

## 四、十个迭代总览

### 4.1 迭代矩阵

| 版本 | 主题 | 工期 | 关键产出 | 依赖 |
|------|------|------|---------|------|
| **v0.40.0** | Foundation | 3-4 周 | Cargo workspace + FRB 脚手架 + Flutter shell + 最小端到端 PoC | v0.39.0 架构桥接版 |
| **v0.41.0** | Terminal Emulator | 4-5 周 | 自写 VT100 终端内核，bash/vim/tmux 可用 | v0.40.0 FRB |
| **v0.42.0** | UI Design System | 3-4 周 | 20+ 自绘 widgets + 主题系统 + icon + a11y | v0.40.0 Flutter 基础 |
| **v0.43.0** | Server Management | 2-3 周 | 侧栏 + 服务器 CRUD + Tab 系统 + Riverpod 模式 | v0.42.0 widgets |
| **v0.44.0** | Terminal Full + SFTP | 3-4 周 | 搜索/补全/ghost/tmux/pane + 完整 SFTP 面板 | v0.41.0 + v0.43.0 |
| **v0.45.0** | AI Panel | 2-3 周 | AI 对话 + 多 Provider + Local AI + 命令抽取 | v0.42.0 + v0.44.0 |
| **v0.46.0** | Settings + Team + Cloud | 3-4 周 | 20 设置面板 + 团队 + K8s/SSM/Snippet | v0.42.0 widgets |
| **v0.47.0** | Monitor + Recording | 2-3 周 | CustomPainter 图表 + 录制回放 + 端口转发 + 代理 | v0.42.0 + v0.43.0 |
| **v0.48.0** | Polish + Perf + A11y | 2-3 周 | 快捷键系统 + 性能审计 + 无障碍 + i18n 全覆盖 | 全部前置 |
| **v0.49.0** | Release Cutover | 2-3 周 | 发布流水线 + 签名 + 自动更新 + feature→main 合并 | v0.48.0 |

**总工期**: 26–35 周 ≈ **6–8 个月**

### 4.2 依赖关系图

```
v0.40.0 (Foundation: Workspace + FRB + Flutter shell)
   │
   ├──> v0.41.0 (Terminal Emulator)
   │       │
   │       └──> v0.44.0 (Terminal Full + SFTP)
   │                │
   │                └──> v0.45.0 (AI Panel)
   │                │
   │                └──> v0.47.0 (Monitor + Recording)
   │
   └──> v0.42.0 (UI Design System)
           │
           ├──> v0.43.0 (Server Management)
           │       │
           │       └──> v0.44.0, v0.47.0
           │
           ├──> v0.45.0, v0.46.0, v0.47.0
           │
           └──> v0.48.0 (Polish)
                   │
                   └──> v0.49.0 (Release Cutover)
```

**关键路径** (决定整体工期): v0.40 → v0.41 → v0.44 → v0.48 → v0.49，合计 14-18 周。

**并行机会**:
- v0.41 (Terminal) 与 v0.42 (Design System) 可部分并行（不同子团队）
- v0.45 / v0.46 / v0.47 可以互相错开并行

---

## 五、功能覆盖率清单（PC 迁移完整性保证）

为确保 Vue 版所有功能在 Flutter 版有对应实现，本节列出**所有迁移对象**及其目标迭代：

### 5.1 Vue 组件迁移映射 (81 组件)

| Vue 目录 | 数量 | 目标迭代 |
|---------|------|---------|
| `components/sidebar/` | 9 | v0.43.0 |
| `components/terminal/` | 14 | v0.41.0 + v0.44.0 |
| `components/sftp/` | 10 | v0.44.0 |
| `components/ai/` | 6 | v0.45.0 |
| `components/settings/` | 20 | v0.46.0 |
| `components/team/` | 4 | v0.46.0 |
| `components/cloud/` | 4 | v0.46.0 |
| `components/snippet/` | 4 | v0.46.0 |
| `components/monitor/` | 7 | v0.47.0 |
| `components/recording/` | 3 | v0.47.0 |
| `components/ui/` | 0 | (空目录，无需迁移) |

### 5.2 Composables 迁移映射 (25 个)

| Composable 组 | 目标迭代 |
|--------------|---------|
| useTerminal / useTerminalSearch / useTerminalAutocomplete / useTerminalGhostText / useKeywordHighlight / useCommandTracker | v0.41.0 + v0.44.0 |
| useTmux | v0.44.0 |
| useSftpPane / useSftpDrag / useTabSftp | v0.44.0 |
| useAiContext / useErrorDetection / useMarkdown | v0.45.0 |
| useMonitor | v0.47.0 |
| useGitSync | v0.47.0 |
| useReconnect | v0.43.0 |
| useShortcuts | v0.48.0 |
| useBroadcast / useCrossTabSearch / useIdleTimer | v0.48.0 |
| useDragLayout | v0.44.0 |
| useConfigExport | v0.46.0 |
| useTeamPermission | v0.46.0 |

### 5.3 Pinia Stores 迁移映射 (14 个)

| Store | 目标迭代 (Riverpod provider) |
|-------|------|
| serverStore / sessionStore | v0.43.0 |
| sftpStore | v0.44.0 |
| aiStore / localAiStore | v0.45.0 |
| settingsStore / teamStore / cloudStore | v0.46.0 |
| snippetStore | v0.46.0 |
| monitorStore / recordingStore | v0.47.0 |
| portForwardStore / proxyStore | v0.47.0 |

### 5.4 Tauri 命令迁移映射 (195 命令 → FRB API)

按模块映射到 FRB bridge crate 下 `src/api/{module}.rs`：

| 命令文件 | 命令数 | FRB bridge 目标 | 迭代 |
|---------|--------|----------------|------|
| ai.rs / local_ai.rs | 17+10=27 | `api/ai.rs` / `api/local_ai.rs` | v0.45.0 |
| server.rs | 13 | `api/server.rs` | v0.43.0 |
| sftp.rs | 13 | `api/sftp.rs` | v0.44.0 |
| recording.rs | 13 | `api/recording.rs` | v0.47.0 |
| team.rs / team_ext.rs | 12+9=21 | `api/team.rs` | v0.46.0 |
| snippet.rs | 12 | `api/snippet.rs` | v0.46.0 |
| ssh.rs / ssh_config.rs | 10+4=14 | `api/ssh.rs` | v0.40.0 + v0.43.0 |
| local_fs.rs | 11 | `api/local_fs.rs` | v0.44.0 |
| cloud.rs | 17 | `api/cloud.rs` | v0.46.0 |
| crypto.rs | 7 | `api/crypto.rs` | v0.40.0 |
| proxy.rs | 7 | `api/proxy.rs` | v0.47.0 |
| port_forward.rs | 5 | `api/port_forward.rs` | v0.47.0 |
| plugin.rs | 5 | `api/plugin.rs` | v0.48.0 |
| settings.rs / fonts.rs | 4+4=8 | `api/settings.rs` | v0.46.0 |
| monitor.rs | 4 | `api/monitor.rs` | v0.47.0 |
| audit.rs | 4 | `api/audit.rs` | v0.46.0 |
| update.rs | 3 | `api/update.rs` | v0.49.0 |
| git_sync.rs | 3 | `api/git_sync.rs` | v0.47.0 |
| config.rs / privacy.rs | 2+2=4 | `api/settings.rs` | v0.46.0 |
| clipboard.rs / menu.rs / portable.rs / tor.rs | 1+1+1+1=4 | `api/system.rs` | v0.48.0 |

**覆盖率核对**: 每个迭代文档的"文件变更清单"必须列出具体命令的 FRB 绑定函数，最终 v0.49.0 前做一次 195 项全量 checklist 核对。

### 5.5 Rust 核心模块 (13 模块 + 集成层)

全部在 v0.40.0 整体迁入 `crates/termex-core/src/`，各模块内部代码**不重构**（只做 import 路径调整）。集成层的 `state.rs` / `local_pty.rs` / `paths.rs` / `lib.rs` 保留在 `crates/termex-tauri/src/` 服务现有 Vue 版。

---

## 六、风险管理

### 6.1 技术风险

| 风险 | 可能性 | 影响 | 缓解策略 |
|------|-------|------|---------|
| 自写 VT100 内核复杂度超估 | 中 | 高 | v0.41.0 第 1 周做 ANSI escape conformance 测试向量，若覆盖率 < 80% 立即评估引入 xterm.dart 作为 fallback |
| Flutter Desktop 在 Linux 上稳定性 | 中 | 中 | 早期 CI 覆盖 Ubuntu 22.04 LTS；若 X11/Wayland 兼容性问题严重，Linux 发布延到 v0.50+ |
| flutter_rust_bridge v2 生态不稳定 | 低 | 中 | 锁定具体版本；每次升级前充分回归 |
| CustomPainter 大数据集性能（终端 / 图表） | 中 | 中 | v0.41.0 / v0.47.0 设置明确 FPS 目标；脏矩形优化作为首选 |
| 自绘 widget 库工作量超估 | 高 | 中 | v0.42.0 预留 4 周；后续迭代中若发现 widget 库不够用再补 |

### 6.2 工程风险

| 风险 | 可能性 | 影响 | 缓解策略 |
|------|-------|------|---------|
| feature 分支与 main 合并地狱 | 高 | 高 | 严格执行 §3.2 分支治理政策；每月依赖同步 |
| 开发者在 6–8 个月里技能转换困难 | 中 | 中 | v0.40–v0.42 用较长迭代周期（3–5 周）给团队留学习时间 |
| 用户抵触更换 UI 框架带来的视觉差异 | 中 | 低 | v0.42 设计系统尽量贴近当前 Element Plus 视觉语言；release notes 提前沟通 |
| 签名证书 / 商店审核中断发布节奏 | 低 | 中 | v0.49.0 前完成所有证书申请；macOS Notarization 流水线早期验证 |

### 6.3 战略风险

| 风险 | 缓解策略 |
|------|---------|
| 方案 D 走不通（极端情况） | feature 分支独立开发，main 分支始终保留 Vue+Tauri 版本作为逃生通道；最坏情况下回退到方案 A 做移动端 |
| 重写过程中用户流失 | main 分支持续发 Vue+Tauri bug-fix 版本（v0.39.x），保证现有用户体验不退化 |
| 6-8 个月工期超支 | 保留紧急路径选项：v0.46 / v0.47 某些功能面板可以按"最小版本"实现，完整版延到 v0.49 后补丁迭代 |

---

## 七、成功标准

v0.49.0 正式发布时必须满足：

### 7.1 功能对等

- [ ] 81 Vue 组件全部有 Flutter 等价实现
- [ ] 25 composables 全部有 Riverpod provider / Dart 服务等价
- [ ] 14 Pinia stores 全部迁移到 Riverpod
- [ ] 195 Tauri 命令全部通过 FRB bridge 可调用
- [ ] 所有现有用户配置（SQLCipher 数据库）无需迁移，直接读取

### 7.2 质量标准

- [ ] Rust core 347 个原有测试全部通过（在 `termex-core` crate 下）
- [ ] FRB bridge 新增测试覆盖所有 195 个 API
- [ ] Flutter widget golden test 覆盖 80% UI 组件
- [ ] Flutter 集成测试覆盖 5 个核心流程（添加服务器 → 连接 → 使用 → SFTP → 断开）
- [ ] 性能: 终端渲染 ≥ 60fps；SFTP 大文件传输无退化；冷启动 < 2s

### 7.3 发布标准

- [ ] 三桌面平台（macOS / Windows / Linux）签名有效
- [ ] 自动更新在三平台可靠工作
- [ ] main 分支 `[backport-flutter]` 标签 commits 全部回填完成
- [ ] Release notes 明确标注"UI 技术栈重构"，提供用户沟通

---

## 八、后续（v0.60.0+ 移动端重启）

PC 迁移完成后，移动端 4 个迭代重启：

| 新版本 | 原版本 (保留内容) | 主题 |
|--------|----------------|------|
| v0.60.0 | v0.40.0-mobile-foundation.md | Mobile Foundation (最小 SSH 客户端) |
| v0.62.0 | v0.42.0-cross-device-sync.md | 跨设备同步 |
| v0.62.1 | v0.42.1-mobile-server-sftp.md | 移动端服务器 CRUD + SFTP |
| v0.64.0 | v0.44.0-mobile-ai-keychain.md | 云端 AI + 原生凭据 + 后台保活 |
| v0.66.0 | v0.46.0-mobile-appstore.md | 触摸手势 + 无障碍 + App Store 上架 |

**关键简化**: Flutter 架构下移动端无需条件编译（Tauri 方案的 `#[cfg(feature = "desktop")]` 工作全部免除）；终端自绘内核直接复用；IPC 通过 FRB 已就绪。v0.50+ 专注移动端 UX。

---

## 九、路线图版本历史

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-04-18 | v1.0 | 首版路线图，锁定方案 D + 10 迭代 PC 迁移 + 移动重启到 v0.50+ |

---

## 十、相关文档

- **v0.40.0 详细设计**: [v0.40.0-pc-flutter-foundation.md](../iterations/v0.40.0-pc-flutter-foundation.md)
- **v0.41.0 – v0.49.0**: 各自在 `docs/iterations/` 下
- **历史 v0.39.0 及之前（Vue+Tauri 时代）**: 保留在 `docs/iterations/` 不变，v0.39.0 是最后一个 Vue+Tauri 正式版本
- **移动端（保留，内容待调整）**: `v0.60.0-mobile-foundation.md` 等
- **项目规范**: [CLAUDE.md](../../CLAUDE.md)
- **架构原设计**: [docs/detailed-design.md](../detailed-design.md)
