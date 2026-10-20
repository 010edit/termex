# Termex Iteration Execution Standards

> 状态：生效中（v0.71.0 起，2026-05-23 制定）
> 适用范围：`docs/iterations/v0.71.0+*.md` 全部迭代文档
> 上位：[`docs/mobile-strategy.md`](mobile-strategy.md) §6 路线图

本文件定义 **所有迭代必须遵循的共享标准**，避免在每个迭代文档里重复 boilerplate。每个迭代仅记录本次的**增量** —— 跨切政策一律引用此文件。

---

## 1. 版本号规范（Semver Strict）

- 所有迭代文档文件名格式：`v{major}.{minor}.{patch}-{scope}-{slug}.md`，例：`v0.71.0-core-termexd-daemon.md`
- 文档内一级标题格式：`# v0.71.0 — <中文标题>`
- 版本字段含义：
  - **major** (0)：1.0 stable release 之前保持 0
  - **minor** (71)：新增功能或破坏性变更 → 升 minor
  - **patch** (0)：修复、补丁、向后兼容的小增量 → 升 patch
- **不允许**的形式：`v0.71`、`v0.71.x`、`v0.70.5`（非 x.y.z）

### scope tag（与 CLAUDE.md 一致）

| scope | 用途 |
|---|---|
| `pc` | 桌面客户端（Flutter 桌面 UI / 打包） |
| `mobile` | iOS / Android Flutter app（含 UI / 平台 API / 移动专属功能） |
| `web` | 未来浏览器/web 客户端 |
| `core` | `crates/termex-core` 业务逻辑（SSH / 加密 / 存储 / 任务模型 / daemon 等） |
| `bridge` | `crates/termex-flutter-bridge` FRB 接线 |
| `homebrew` | Homebrew formula / tap |

---

## 2. Migration ID 注册表（全局唯一，禁止冲突）

所有 SQLite migration 在 `crates/termex-core/src/storage/migrations.rs` 集中编号；插入新 migration **必须先在本表登记**，再写代码。如果两个迭代并行需要 migration，**后到的迭代必须 +1**，绝对不允许冲突。

| Migration # | 描述 | 引入迭代 | 表 / 列改动 | 测试基线 count |
|---|---|---|---|---|
| #1–#25 | 历史 migration | v0.x | (略) | 25 |
| **#26** | `tasks` 表（任务模型，daemon + 客户端共享） | v0.71.0 | new table `tasks` | 26 |
| **#27** | `device_push_tokens` 表 | v0.72.2 | new table | 27 |
| **#28** | `egress_profiles` 表 + `servers.egress_profile_id` 列 | v0.74.0 | new table + column | 28 |
| **#29** | `task_costs` 表（成本透明） | v0.74.1 | new table | 29 |
| **#30** | `task_metrics` 表（可靠性指标） | v0.75.0 | new table | 30 |
| #31+ | 待分配 | — | — | — |

**强制流程**：
1. 写迭代文档时先来这里登记预期的 migration 号
2. 实现时同步更新 migration 相关测试断言（migration 数量 / 最新版本号）；测试放在 `crates/*/tests/` 或 `crates/termex-core/src/storage/` 的测试模块中
3. 每个 migration 必须有对应 down 方向说明（即使是 "irreversible，请用历史 dump 恢复"）

---

## 3. 测试金字塔（每迭代必须声明）

每个迭代文档的 "验收清单" 段必须明确各层覆盖：

| 层 | 范围 | 必填 | 跑法 |
|---|---|---|---|
| **单元测试**（Rust） | termex-core / termex-core-private / termexd 内部逻辑 | ✅ | `cargo test --workspace --lib --tests` |
| **Bridge 测试** | termex-flutter-bridge API 边界 | 涉及 bridge 改动时 ✅ | `cd crates/termex-flutter-bridge && cargo test --features private` |
| **Widget 测试**（Flutter） | termex_shared 中新增 UI 组件 | UI 改动时 ✅ | `cd app && flutter test test/<feature>/` |
| **Integration 测试**（mock backend） | 端到端流（mock daemon / mock FCM / mock SSH） | 跨层流程时 ✅ | `flutter test integration_test/` |
| **真机验收** | iOS 模拟器 + Android 设备双端走通核心 path | 涉及平台 API（FG service / BGTask / 推送 / 语音 / 生物识别） ✅ | 手工，记录在 "真机验收清单" |

**禁止**：跳过单元测试或 widget 测试。**真机验收**可推迟到下一个 patch 但必须在主 minor release 前完成。

---

## 4. i18n 政策

按 CLAUDE.md "No hardcoded strings for user-facing text"：

- **任何 UI 字符串** 必须走 i18n
- 迭代文档需在 "文件清单" 段记录 **预期新增 i18n keys 数量**（如：本迭代新增 ~24 个 keys）
- 当迭代涉及面向用户文案时，需更新：
  - `packages/termex_shared/lib/l10n/intl_en.arb`（英文 base）
  - `packages/termex_shared/lib/l10n/intl_zh.arb`（中文）
- 流程：先在 .arb 文件加 key + 双语翻译 → flutter pub run intl_translation 生成 → 代码用 `S.of(context).keyName`
- **不允许** 在迭代中遗留 `Text('硬编码字符串')`（lint 已配 `avoid_hardcoded_strings` rule）

---

## 5. Release Notes 模板

每个迭代必须在文档末尾产出 "Release Notes" 段（草稿），供发版 CHANGELOG.md / GitHub Release 直接引用：

```markdown
## Release Notes (v0.X.Y — 2026-XX-XX)

### Added
- ...

### Changed
- ...

### Fixed
- ...

### Deprecated
- ...

### Security
- ...

### Breaking
- ...（破坏性变更，迁移步骤简述）

### Migration steps for end users
- ...（若有用户侧动作）

### Acknowledgments
- Contributors / community feedback
```

格式遵循 [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)。

---

## 6. Rollback 政策

破坏性变更（特别是 migration / 协议变更）必须有 rollback 路径声明：

| 变更类型 | Rollback 方法 |
|---|---|
| Migration up（不可逆 SCHEMA 变更） | 标注 "irreversible"；用户需手动 sqlite3 dump → 旧版本重 import |
| Migration up（可逆） | 写 `DOWN` SQL（仍 store 在 migrations.rs 注释里）|
| WS 协议字段新增 | 兼容老 client（默认值 / optional 字段）|
| WS 协议字段删除 | bump message_type 版本（如 `task.assign_v2`）|
| Pro/OSS 边界变动 | 老 client 退化路径必须可工作 |

每个迭代 "风险与对策" 段需明确 rollback 实现方式。

---

## 7. Telemetry 政策

- **OSS** 端：默认 **零上报**，本地可选记录到 `task_metrics` 表（v0.75.0+ 引入），用户可在开发者模式查看
- **Pro** 端：可选开启 telemetry 上报（用户首次启动时弹 opt-in 对话框）；上报内容仅限：迭代号、指标聚合值（无 PII / 无任务内容 / 无 prompt 内容）
- 迭代文档需声明：本次新增是否涉及指标采集；若涉及，本地 metric name 列表 + 数据生命周期

---

## 8. 文档结构规范

每个迭代文档必须包含以下段落（顺序固定）：

```markdown
# v{x.y.z} — <中文标题>

> 状态：<规划中 / 实施中 / 实施完成（YYYY-MM-DD） / 已废弃>
> 战略上位：[strategy-doc-link]
> 前置依赖：v{x.y.z} 列表
> 标准：[`docs/iteration-standards.md`](../iteration-standards.md) 全部 §1-§7

## 一、背景与目标

## 二、技术设计

## 三、文件清单
### 新增
### 改动
### 不动（明确）

## 四、数据库 / 协议变更
### Migration
### Wire protocol

## 五、i18n 新增 keys
### 列表 / 数量预估

## 六、测试金字塔（按 §3）
### 单元 / Widget / Integration / 真机

## 七、验收清单（编号 + 操作 + 期望）

## 八、风险与对策（含 Rollback）

## 九、与战略文档的映射

## 十、Release Notes（草稿）
```

---

## 9. 文档审计 checklist

合并迭代到 plan 时人工 review 以下 checklist：

- [ ] 文件名 x.y.z 格式
- [ ] 一级标题 `# v{x.y.z}` 格式
- [ ] 前置依赖列出所有上游迭代
- [ ] 引用 iteration-standards.md
- [ ] migration 号已登记本表
- [ ] 测试金字塔 5 层覆盖声明
- [ ] i18n keys 数量声明
- [ ] Release Notes 草稿存在
- [ ] Rollback 方法声明
- [ ] 与战略文档章节映射

---

## 附 A · 变更历史

| 日期 | 变更 |
|---|---|
| 2026-05-23 | 初版（v0.71.0 起强制） |
