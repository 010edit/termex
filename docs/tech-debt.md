# Tech Debt — post Flutter Migration (v0.50+)

> **历史文档**：文中部分路径指向已删除的 Tauri/Vue 老栈（`src-tauri/`、`src/`）。
> 当前栈为 Flutter + Rust workspace；未完成项请以代码与 issue 为准。

> 在 v0.40–v0.49 迁移过程中发现但未在本次迁移窗口修复的技术债务。优先级与 v0.50+ 的迭代规划对齐。

---

## P0 — 阻断 Flutter 产品完整性（v0.39 审计遗留）

### T-9. SSH 代理链路 / 端口转发未对 Flutter 暴露
- **位置**：`src-tauri/src/ssh/{chain_connect,forward,exit_proxy}.rs`（使用 `tauri::AppHandle`）
- **现状**：未处理 — 三个文件共约 1200 LOC，迁移需要大规模 `AppHandle → BoxedEmitter` 重构 + exit_proxy 的 tokio cancellation 集成。单会话风险过高，推迟到 v0.51
- **症状**：v0.50.1 已实现 `open_ssh_session` 直连路径（`crates/termex-flutter-bridge/src/api/ssh.rs`），但 bastion 链 / SOCKS5 动态转发 / 退出代理仍仅在 Tauri 侧可用
- **影响**：Flutter 用户遇到跳板机场景会退回 Tauri legacy 通道
- **建议**：v0.51 专门 1-2 周窗口处理；模式同 T-10 sftp 迁移

### T-10. `sftp` 模块尚未迁入 termex-core
- **状态**：✅ **已完成（v0.50.x）**
- **变更**：
  - 模块迁至 `crates/termex-core/src/sftp/`，新增 `SftpEventEmitter` trait
  - `src-tauri/src/sftp/` 改为 shim，新增 `TauriSftpEmitter` 适配器
  - `crates/termex-flutter-bridge/src/api/sftp.rs` 11/11 TODOs 全部消除
  - `session_registry` 扩展持有 `SftpHandle`，`ensure_sftp` 提供按需打开 + 缓存
  - 新增 `FrbSftpEmitter` + `poll_sftp_progress` 事件轮询 API

### T-11. `local_ai` 模块尚未迁入 termex-core
- **状态**：✅ **模块迁移完成（v0.50.x）**；bridge 接线 4/9 完成，5 个 subprocess/HTTP 相关 TODO 待续
- **变更**：
  - `binary_manager.rs` / `downloader.rs` / `storage.rs` / `mod.rs` 全部迁入 `crates/termex-core/src/local_ai/`
  - 抽出 `port_check.rs`（不可判定的纯函数）供 bridge 复用
  - `health_check.rs` 保留在 `src-tauri/`（因 `AppState` 重启监控逻辑与 Tauri 耦合）
  - bridge `local_ai.rs` 已接通：`local_ai_health` / `local_ai_list_models` / `local_ai_delete_model` / `local_ai_base_url` / `local_ai_check_disk_space`
- **剩余 5 TODO**：`local_ai_start`（subprocess spawn via LlamaServerState.start）、`local_ai_stop`、`local_ai_download_model`（HTTP range + progress stream）、`local_ai_cancel_download`、`local_ai_cancel_auto_start`

### T-12. AI 对话流式 / 历史 / 配额 未完整接线
- **状态**：⚠️ **部分完成（v0.50.x）** — DB/配置持久化层 6/15 TODOs 已接线，9 个 provider HTTP 调用待续
- **已完成**：
  - `ai_create_conversation` / `ai_list_conversations` / `ai_delete_conversation` / `ai_rename_conversation` 全部接通 `ai_conversations` 表
  - `ai_get_messages` + `ai_persist_user_message` + `ai_persist_assistant_message` 接通 `ai_messages` 表
  - `ai_save_provider_config` / `ai_load_provider_config` 接通 `settings` 表 + keychain（API key 走 OS 钥匙串）
- **剩余 9 TODO**：全部为 provider HTTP 调用 + SSE 流式回复解析（Claude/OpenAI/Ollama/local_llama 各家 API 不同）。建议 v0.51 按 provider 分工并行实现
- **建议**：流式回复用 Phase 1 同款 queue + poll 模式（新建 `ai_chunk_queue` + `poll_ai_chunks`）

### T-13. 团队同步 / 冲突 / passphrase 持久化未接线
- **状态**：⚠️ **部分完成（v0.50.x）** — DB/keychain 4/9 TODOs 已接线，5 个 Git-同步 TODO 保留
- **已完成**：
  - `team_list_conflicts` / `team_resolve_conflict` 接通 `team_pending_conflicts` 表
  - `team_verify_passphrase` / `team_change_passphrase` 接通 `team_passphrase` keychain 条目（常数时间比较）
- **剩余 5 TODO**：`team_get_members` / `team_remove_member` / `team_update_role` / `team_invite_accept` / `team_sync_now` 依赖 Git + `team.json` 工作流，等同于把 `src-tauri/src/commands/team.rs` 的 ~500 LOC git2 集成搬到 bridge。建议 v0.51 单独处理

---

## P1 — 下一迭代优先处理

### T-1. `RecordingPlayer._loadFile()` 占位实现
- **位置**：[app/lib/features/recording/recording_player.dart](../app/lib/features/recording/recording_player.dart)
- **症状**：目前加载空 `AsciicastFile` stub；真实 `.cast` 文件通过 FRB `recording_load_file(path)` 读取的路径在 v0.47 落下
- **影响**：回放功能 UI 完整，但无法播放已有录制
- **建议**：v0.50 在 `api/recording.rs` 中补 `load_file_ndjson(path) -> Result<String>`，Dart 侧调用后解析

### T-2. 自动更新仅 scaffold
- **位置**：[app/lib/system/auto_updater_*.dart](../app/lib/system/)
- **症状**：`MacAutoUpdater` / `WindowsAutoUpdater` / `LinuxAutoUpdater` 继承 `FakeAutoUpdater` 提供状态机骨架，但真实 Sparkle / MSIX / AppImageUpdate 桥接未接
- **影响**：v0.49 beta 需手动下载
- **建议**：v0.60.1 接入 flutter_sparkle（或自写 Method Channel），Windows 走 `ms-appinstaller://`，Linux 调 `appimageupdatetool`

### T-3. Delta 更新占位
- **位置**：appcast.xml / [v0.49.0-pc-release-cutover.md §5.3.5](iterations/v0.49.0-pc-release-cutover.md)
- **症状**：delta URL 已写入 appcast 解析，但 CI 中未生成 bsdiff delta 包
- **影响**：macOS 用户每次下载全量 DMG（40+ MB）
- **建议**：v0.60.1 在 `flutter-release.yml` 加 bsdiff step，对上一 stable 版本生成 delta，附到 appcast

---

## P2 — 观望

### T-4. CrashReporter 为 `NullCrashReporter`
- **位置**：[app/lib/services/crash_reporter.dart](../app/lib/services/crash_reporter.dart)
- **症状**：符合 CLAUDE.md「遥测必须 opt-in」规定，v0.49 不上报任何崩溃
- **影响**：只能靠用户主动报告 bug
- **决策**：v0.50+ 评估是否集成 Sentry self-hosted（用户 opt-in，数据留在自有基础设施）。**默认仍关闭。**

### T-5. 多窗口支持 (Cmd+N)
- **症状**：Vue 版支持，Flutter 版暂未恢复
- **影响**：少数重度用户受影响
- **建议**：v0.51 调研 Flutter desktop multi-window（目前实验性），评估投入

### T-6. 打印视图
- **症状**：Vue 版 `window.print()` 走 WebView，Flutter 无等价
- **影响**：极少数用户（合规审计场景）
- **建议**：v0.51+ 若有用户明确需求再考虑；可能用导出 PDF 替代

---

## P3 — 长期观察

### T-7. Flutter desktop 内存占用
- **症状**：空闲状态下比 Tauri 略高（+20–40 MB），Flutter 引擎占用
- **影响**：在 4 GB 内存设备上略有差距
- **建议**：v0.52+ 评估是否启用 Dart AOT + tree-shake 降体积

### T-8. `flutter_distributor` 3.x 破坏性变更追踪
- **症状**：上游 API 快速变化，CI 偶尔需要 pin
- **建议**：每季度跟进一次，必要时切到自写脚本

---

## 已解决（v0.40–v0.49 中）

- ~~ Vue 组件 xterm.js WebGL 与 Safari Tech Preview 冲突 ~~ → 自绘终端取代
- ~~ Tauri v2 mobile 终端键盘集成差 ~~ → Flutter 自带键盘处理
- ~~ 主题切换需重启 ~~ → v0.42 热切换

---

## 维护规则

- 本文件**仅记录跨迭代债务**，单迭代 TODO 走 GitHub issue
- 每个 v0.5x 迭代 kickoff 时评审一次
- 新增债务附上：位置、症状、影响、建议方案
- 解决后移入「已解决」区，保留追溯
