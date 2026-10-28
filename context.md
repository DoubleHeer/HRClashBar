# ClashBar 项目上下文

> 生成时间：2026-10-28。当前 checkout：`main`，commit `1b25154`（浅克隆）。  
> 目标：让后续开发、排障和代码修改能快速定位真实实现，避免重复扫描整仓。

## 1. 项目概览

ClashBar 是面向 macOS 13+ 的原生菜单栏代理客户端，底层由 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 驱动。它不是浏览器扩展，也不是跨平台 Web 应用；UI 主要使用 SwiftUI，菜单栏集成和部分弹层、窗口管理依赖 AppKit。

- 应用形态：菜单栏常驻 App（`NSApplicationDelegateAdaptor` + accessory 激活策略），没有常规主窗口。
- 技术栈：Swift 6.2、SwiftPM、SwiftUI、AppKit、Combine、Foundation、CoreWLAN、CoreLocation、Security、ServiceManagement。
- 两个可执行目标：
  - `ClashBar`：主 App，路径 `Sources/ClashBar`。
  - `ClashBarProxyHelper`：系统代理特权 Helper 守护进程，路径 `Sources/ProxyHelper/Daemon`。
- 分发：Homebrew cask、GitHub Release DMG、Cloudflare Workers 文档站。
- 版本：当前 changelog 最新为 v0.3.6，当前 release 元数据由 `.github/workflows/release-dmg.yml` 生成。

## 2. 仓库布局

```text
Sources/
  ClashBar/
    App/          应用入口、依赖容器
    Core/         工具、扩展、基础 UI 组件、资源定位
    Models/       mihomo API 与配置的数据模型
    Resources/    本地化、资源、配置模板
    Services/     内核、API、配置、代理、权限等服务
    ViewModels/   主 ViewModel 扩展和分页数据 Store
    Views/        菜单栏内容、弹层、五个主标签页
  ProxyHelper/    系统代理 helper 的 daemon 与 LaunchDaemon 模板
  ProxyHelperShared/ App 与 helper 共享协议
docs/             Fumadocs/Next/OpenNext 文档站
Scripts/          构建、打包、DMG、release note 脚本
.github/          正式发布和 beta release workflow
Package.swift     SwiftPM 清单
Makefile          面向本机和发布的构建入口
```

## 3. 应用启动与 UI 生命周期

### 3.1 入口链

- `Sources/ClashBar/App/ClashBarApp.swift`：`@main` App，注册 Settings 场景和全局命令。
- `Sources/ClashBar/App/AppDelegate.swift`：应用启动、菜单栏控制器创建、窗口抑制、退出清理。
- `Sources/ClashBar/App/AppDependencies.swift`：构建实际使用的依赖，包括进程管理器、配置服务、系统代理、TUN、网络/SSID 监控等。
- `Sources/ClashBar/ViewModels/AppViewModel.swift`：主 `ObservableObject`，持有所有面向 UI 的状态和 Store。
- `Sources/ClashBar/ViewModels/AppViewModel+Initialization.swift`：目录/日志初始化、恢复偏好、恢复远程订阅、启动轮询、网络/SSID 监控。

### 3.2 菜单栏与弹层

- `Sources/ClashBar/Views/StatusBar/StatusItemController.swift`：创建 `NSStatusItem`、Popover、菜单动作、面板显示/隐藏。
- `Sources/ClashBar/Views/StatusBar/StatusItemContentView.swift`：离屏合成菜单栏模板图标与速率文字。
- `Sources/ClashBar/Views/MenuBar/Root/MenuBarRootView.swift`：面板根视图、固定高度、标签切换。
- `Sources/ClashBar/ViewModels/PopoverLayoutModel.swift`：Popover 尺寸与布局状态。
- `Sources/ClashBar/Views/MenuBar/*`：Proxy、Rules、Connections、Logs、System 五个标签页。

### 3.3 窗口约束

应用刻意禁用窗口状态恢复并抑制非面板窗口，避免纯菜单栏 App 启动/恢复会话时弹出空白窗口。改动窗口行为时要同步检查：

- `ClashBarApp.swift` 的 Settings suppressor。
- `AppDelegate.swift` 的 `applicationSupportsSecureRestorableState`、`applicationShouldHandleReopen`、`applicationShouldOpenUntitledFile`、窗口通知。

## 4. 核心运行时

### 4.1 进程与内核

- `Sources/ClashBar/Services/CoreService.swift`：
  - `MihomoProcessManager` 启动、停止、重启 mihomo 进程。
  - 使用 `mihomo -d <workdir> -f <config> -ext-ctl <controller>`。
  - 启动前使用 `mihomo -t` 校验配置。
  - 收集 stdout/stderr，经 `LineAccumulator` 和 `LogFloodGate` 限流后进入日志。
  - 支持本地下载/解压 mihomo 内核（具体逻辑在同一文件后半段）。
- `Sources/ClashBar/ViewModels/AppViewModel+Lifecycle.swift`：
  - `startCore`、`stopCore`、`restartCore`、`performPrimaryCoreAction`、`shutdownForTermination`。
  - 启动前后处理配置、TUN、Provider、系统代理恢复和状态同步。
  - 将最后成功启动的配置路径写入 UserDefaults。

### 4.2 配置目录

- 运行数据根目录：`~/Library/Application Support/clashbar`。
- 子目录：`config`、`logs`、`state`、`icon`、`core`。
- 内置内核会被复制/定位到 `~/Library/Application Support/clashbar/core/mihomo`。
- `Sources/ClashBar/Services/ConfigService.swift`：
  - `WorkingDirectoryManager` 管理目录与路径校验。
  - `ConfigDirectoryManager` 扫描 `yaml/yml`、选择配置文件。
  - `ConfigImportService` 校验/写入远程配置，限制远程配置大小，内容不变时不写盘。
  - 配置文件路径必须位于应用根目录内，避免路径逃逸。
- `Sources/ClashBar/Services/ConfigDirectoryMonitor.swift`：监听配置目录变化，删除/新增配置时刷新列表并触发必要的内核重载。

### 4.3 mihomo API

- `Sources/ClashBar/Services/MihomoAPIService.swift` 是唯一的 API 传输层：
  - HTTP endpoint 枚举覆盖 version、traffic、memory、logs、configs、proxies、rules、providers、connections、cache、upgrade 等。
  - 通过 Bearer secret 鉴权。
  - GET 请求在可重试错误下最多重试 3 次。
  - 普通请求、长请求、WebSocket 使用不同 URLSession。
  - 提供 `makeWebSocketTask(for:)` 供流量、内存、连接、日志流使用。
- API 地址优先来自当前配置文件的 `external-controller`，由 `AppViewModel+Validation.swift` / `AppViewModel+RemoteConfig.swift` 解析并更新。
- 相关模型位于 `Sources/ClashBar/Models/`：
  - `Runtime.swift`：`VersionInfo`、`TrafficSnapshot`、`MemorySnapshot`、`APIHealth`、`CoreMode`。
  - `Proxy.swift`：`ProxyGroupsResponse`、`ProxyGroup`、`ConfigSnapshot`。
  - `Rules.swift`、`Connection.swift`、`Provider.swift`、`Log.swift`。

### 4.4 轮询与实时流

- `AppViewModel+Polling.swift`：按数据获取策略启动高/中/低频轮询；标签页激活时刷新对应数据；系统代理和系统设置定期同步。
- `AppViewModel+Streams.swift` 与 `Services/StreamCoordinator.swift`：WebSocket 流管理，支持断开重连和取消。
- 四种流：
  - `traffic`：实时上下行速率、总流量、历史 sparkline。
  - `memory`：内核内存快照。
  - `connections`：活跃连接列表。
  - `logs`：内核日志，按等级过滤。
- 面板关闭时流量曲线仍保留后台历史，只重置面向 UI 的累计展示值。

## 5. 主要功能模块

### 5.1 Proxy 页

- 配置文件选择、本地导入、远程订阅导入/更新、自动更新。
- 内核 Start/Restart/Stop。
- 模式切换：Rule / Global / Direct。
- 系统代理开关、TUN 开关、TUN 协议栈选择。
- 代理组展开、节点切换、延迟测试、Provider 更新。
- 相关代码：
  - `Views/MenuBar/ProxyTabView.swift`
  - `Views/MenuBar/ProxyProvidersAndGroupsView.swift`
  - `ViewModels/AppViewModel+Proxy.swift`
  - `ViewModels/AppViewModel+Providers.swift`
  - `ViewModels/ProxyGroupsViewModel.swift`
  - `ViewModels/AppViewModel+RemoteConfig.swift`
  - `ViewModels/AppViewModel+LocalConfig.swift`

### 5.2 Rules 页

- 规则列表与统计、按类型/策略/Provider 过滤。
- Provider 更新。
- 相关代码：
  - `Views/MenuBar/RulesTabView.swift`
  - `ViewModels/RulesViewModel.swift`
  - `ViewModels/AppViewModel+Providers.swift`

### 5.3 Connections 页

- 活跃连接列表、按规则/链/网络过滤、关闭单个连接、清空连接。
- 相关代码：
  - `Views/MenuBar/ConnectionsTabView.swift`
  - `ViewModels/ConnectionsViewModel.swift`
  - `ViewModels/Stores/ConnectionsStore.swift`
  - `Models/Connection.swift`

### 5.4 Logs 页

- 客户端日志与内核日志。
- 按等级、来源、关键词过滤。
- 直接调整 mihomo `log-level`。
- 日志文件位于 `~/Library/Application Support/clashbar/logs`。
- 相关代码：
  - `Views/MenuBar/LogsTabView.swift`
  - `ViewModels/LogsViewModel.swift`
  - `ViewModels/Stores/LogsStore.swift`
  - `ViewModels/AppViewModel+Logging.swift`
  - `Services/AppLogStore.swift`
  - `Models/Log.swift`

### 5.5 System 页

- 语言、外观、状态栏显示模式。
- 端口、allow-lan、IPv6、TCP 并发、日志等级。
- 开机启动、应用更新检查、内核/GEO 升级、诊断。
- 相关代码：
  - `Views/MenuBar/SystemTabView.swift`
  - `ViewModels/SystemTabViewModel.swift`
  - `ViewModels/AppViewModel+Settings.swift`
  - `ViewModels/AppViewModel+SettingsPatch.swift`
  - `ViewModels/AppViewModel+Maintenance.swift`
  - `ViewModels/AppViewModel+Persistence.swift`

### 5.6 远程机器

- 可将当前 App 连接到远程 mihomo API。
- 相关代码：
  - `Views/MenuBar/Root/RemoteMachineManagerView.swift`
  - `ViewModels/AppViewModel+RemoteMachine.swift`
  - `ViewModels/Stores/RemoteMachineStore.swift`
  - `Models/RemoteMachine.swift`
- 远程模式下本地进程操作会被跳过，本地 UI 状态需要谨慎处理。

### 5.7 SSID 策略

- 基于当前 Wi-Fi SSID 自动切换配置文件。
- 相关代码：
  - `ViewModels/AppViewModel+SSIDStrategy.swift`
  - `Services/SSIDMonitorService.swift`
  - `Models/SSIDStrategyRule.swift`
- 需要 CoreLocation/CoreWLAN 授权；策略命中目标配置缺失时跳过并记录日志。

## 6. 系统代理与特权 Helper

- `Sources/ClashBar/Services/SystemProxyService.swift`：读写系统代理设置、查询端口、管理绕过列表、调用/检查 Helper。
- `Sources/ClashBar/Services/ProxyHelperInstaller.swift`：安装 LaunchDaemon/PrivilegedHelperTools 并执行加载/校验。
- `Sources/ProxyHelperShared/ProxyHelperProtocol.swift`：App 与 Helper 的共享协议。
- `Sources/ProxyHelper/Daemon/main.swift`：特权 Helper 实现。
- `Sources/ProxyHelper/LaunchDaemons/com.clashbar.helper.plist`：系统级 daemon 配置。

当前 Helper 安装流程（v0.3.6）会：

1. 从打包 App 中复制 Helper 到 `/Library/PrivilegedHelperTools/com.clashbar.helper`。
2. 安装 plist 到 `/Library/LaunchDaemons/com.clashbar.helper.plist`。
3. 清除 `com.apple.quarantine` 隔离属性。
4. 执行 `launchctl bootstrap/kickstart`，失败时不写成功版本标记。

注意：

- 系统代理依赖打包后的 `.app`，开发目录直接运行可能不可用。
- 首次开启系统代理需要管理员授权。
- 不要在同一时间让多个 mihomo/Clash 客户端接管系统代理。

## 7. TUN 模式

- `Sources/ClashBar/Services/TunService.swift`：处理 TUN 权限和运行态配置。
- `ViewModels/AppViewModel+Tun.swift`：TUN 开关、协议栈切换、启动恢复、状态校验。
- TUN 开启需要 mihomo 二进制具备 root + setuid 权限。
- 支持协议栈：`system`、`gvisor`、`mixed`、`mips`。
- `mips` 需要 mihomo v1.19.31 或更高版本，低版本会自动置灰并提示升级。
- TUN 协议栈选择会被持久化，重新启动 App/内核后自动恢复。

## 8. 数据持久化与偏好

### 8.1 文件

| 位置 | 用途 |
| --- | --- |
| `~/Library/Application Support/clashbar/config` | YAML/YML 配置文件 |
| `~/Library/Application Support/clashbar/logs` | `clashbar.log`、`mihomo.log` |
| `~/Library/Application Support/clashbar/state` | 远程订阅、SSID 策略、设置等状态 |
| `~/Library/Application Support/clashbar/icon` | Provider/代理组图标缓存 |
| `~/Library/Application Support/clashbar/core` | mihomo 内核 |

### 8.2 UserDefaults

关键键位于 `AppViewModel+Persistence.swift` 和相关扩展，包括：

- 选中的配置文件名。
- 最后成功启动的配置路径。
- UI 语言、外观模式、状态栏显示模式。
- 系统代理退出前状态。
- 远程订阅列表、SSID 策略、可编辑设置快照。

修改设置逻辑时要区分：

- `suppressSettingsPersistence`：临时阻止写盘。
- `preserveLocalSettingsOnNextSync`：内核重启时保留本地覆盖设置。
- `pendingConfigSwitchOverlaySettings` / `pendingAppLaunchOverlaySettings`：配置切换或启动恢复的临时覆盖层。

## 9. 构建与发布

### 9.1 本地构建

```sh
make build                 # 不包含 mihomo core 的 dist/ClashBar.app
make build WITH_CORE=1     # 打包内置 mihomo
make dist WITH_CORE=1      # 构建 app + DMG
make dmg                   # 仅从已有 app 生成 DMG
make clean                 # 清理 .build/dist/.swiftpm/Packages
```

`make format` 会运行 `swiftformat` 和 `swiftlint`。

### 9.2 发布

- `.github/workflows/release-dmg.yml`：
  - tag push 或手动触发。
  - 按 Conventional Commits 自动升版本。
  - 在 macOS 15 上并行构建 arm64/x86_64，含 core / no-core 四种 DMG。
  - 上传 artifact，发布 GitHub Release。
- `.github/workflows/release-dmg-beta.yml`：
  - 仅支持从 `alpha` 分支手动触发。
  - 生成 beta release 并上传 DMG。

### 9.3 文档站

- 文档站源码在 `docs/`，技术栈为 Next + Fumadocs + OpenNext + Cloudflare Workers。
- 内容位于 `docs/content/docs/*.mdx`，元信息在 `docs/content/docs/meta.json`。
- 更新日志由 `CHANGELOG.md` 解析生成。
- 常用命令：

```sh
cd docs
pnpm install
pnpm dev
pnpm build
pnpm preview
pnpm deploy
```

## 10. 代码约定

- 主线程模型：`AppViewModel` 标为 `@MainActor`，UI 状态变更必须在主线程。
- 服务可注入：核心服务使用协议或依赖容器，便于测试和替换。
- Store 分离：流量、连接、日志、代理、远程机器等状态由独立 `ObservableObject` Store 管理。
- API 边界清晰：视图不直接发 HTTP；所有 mihomo API 调用通过 `MihomoAPIService` / `AppViewModel`。
- 本地化：UI 文案集中在 `Sources/ClashBar/Resources/Localization/*.lproj/Localizable.strings`，新增文案必须同步中英两版。
- 配置安全：所有配置路径必须经过 `WorkingDirectoryManager.normalizeAndValidateWithinRoot`。
- 日志治理：内核日志洪泛由 `LogFloodGate` 按秒窗口限流并折叠重复行。

## 11. 常改入口索引

| 需求 | 优先查看 |
| --- | --- |
| 新增菜单栏命令/快捷键 | `App/ClashBarApp.swift` 的 `AppCommands` |
| 修改启动/退出行为 | `App/AppDelegate.swift`、`AppViewModel+Initialization.swift`、`AppViewModel+Lifecycle.swift` |
| 新增 mihomo API | `Services/MihomoAPIService.swift` 的 `Endpoint`、模型、ViewModel 调用 |
| 修改配置导入/热加载 | `Services/ConfigService.swift`、`ConfigDirectoryMonitor.swift`、`AppViewModel+RemoteConfig.swift` |
| 修改代理组/节点 UI | `Views/MenuBar/ProxyTabView.swift`、`ProxyProvidersAndGroupsView.swift`、`ViewModels/AppViewModel+Proxy.swift` |
| 修改连接页 | `Views/MenuBar/ConnectionsTabView.swift`、`ViewModels/ConnectionsViewModel.swift`、`Stores/ConnectionsStore.swift` |
| 修改日志页 | `Views/MenuBar/LogsTabView.swift`、`ViewModels/LogsViewModel.swift`、`Stores/LogsStore.swift`、`Services/AppLogStore.swift` |
| 修改设置页 | `Views/MenuBar/SystemTabView.swift`、`ViewModels/SystemTabViewModel.swift`、`AppViewModel+Settings.swift`、`AppViewModel+Persistence.swift` |
| 修改系统代理 | `Services/SystemProxyService.swift`、`ProxyHelperInstaller.swift`、`AppViewModel+SystemProxy.swift`、helper daemon |
| 修改 TUN | `Services/TunService.swift`、`AppViewModel+Tun.swift` |
| 修改流量显示 | `Stores/TrafficStore.swift`、`Views/MenuBar/TrafficSparklineView.swift`、`StatusItemContentView.swift` |
| 修改文档站 | `docs/content/docs/*.mdx`、`docs/src/` |
| 修改 release | `Scripts/*.sh`、`.github/workflows/*.yml` |

## 12. Ant Design 参考资料

本仓库自身是 Swift/AppKit 应用，没有使用 Ant Design 组件库。项目根目录已读取 Ant Design 官方聚合文档 `https://ant.design/llms-full.txt`，用于后续可能新增 Web/Webview 界面或文档站 UI 时的规范参考。

文档版本覆盖约 75 个组件，共 657 个二级标题段落，内容包括：

- 布局：`Layout`、`Grid`、`Flex`、`Space`。
- 导航：`Menu`、`Tabs`、`Segmented`、`Breadcrumb`、`Pagination`、`Steps`。
- 数据录入：`Form`、`Input`、`Select`、`Switch`、`Radio`、`Checkbox`、`Cascader`、`DatePicker`、`Upload`、`Transfer`、`TreeSelect`。
- 数据展示：`Table`、`List`、`Descriptions`、`Card`、`Tag`、`Badge`、`Avatar`、`Tree`、`Timeline`、`Collapse`、`Result`、`Empty`、`Skeleton`、`Statistic`、`Progress`、`Typography`。
- 反馈：`Alert`、`Message`、`Notification`、`Modal`、`Drawer`、`Tooltip`、`Popover`、`Popconfirm`、`Spin`、`Result`。
- 通用：`Button`、`Icon`、`Divider`、`ConfigProvider`。

若需要创建 Ant Design 风格的 Web UI，优先阅读对应组件的 `When To Use`、`API`、`Design Token` 和 `Semantic DOM` 小节，而不是直接套用现有 SwiftUI 视觉语言。

## 13. 开发验证建议

修改后建议按以下顺序检查：

1. `swift build` 或 `make build` 确认编译。
2. `make format` 检查 Swift 格式与 lint。
3. 修改 UI 文案时检查中英 `Localizable.strings`。
4. 修改 API 时检查远程机器模式是否兼容。
5. 修改系统代理/TUN 时在真实 `.app` 环境下验证权限与重启恢复。
6. 修改日志相关逻辑时观察洪泛限制和文件落盘。
7. 修改配置导入时验证路径限制、内容校验和热重载行为。

## 14. 排障快速参考

- 内核启动失败：查看 `Logs`、`~/Library/Application Support/clashbar/logs/mihomo.log`，确认配置文件通过 `mihomo -t`。
- 系统代理无效：确认 App 位于 `/Applications`、Helper 已安装且启动、没有其它 Clash 客户端抢占、必要时 Restart 内核。
- TUN 无法开启：确认 mihomo 二进制存在、setuid/root 权限正确、当前内核版本支持所选协议栈。
- 菜单栏图标异常：检查 `StatusItemContentView`、`StatusBarViewModel`、状态栏显示模式和品牌图标资源。
- 配置不生效：确认修改的是运行中的配置文件、外部控制器地址正确、Provider 更新完成。
