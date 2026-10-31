# QuotaBar

原生 macOS 菜单栏用量看板，显示 Claude / Codex 的具体 Token 数和订阅额度。Swift + SwiftUI + AppKit，macOS 14 或更高版本，无第三方依赖。

0.6.0：新增 USD「API 参考折合」，在两家用量卡片、模型明细、趋势总览及小／中号组件中显示。金额与所选统计范围同步。输入、输出、缓存读取、缓存写入分别按模型单价计算；悬停查看金额构成，点击美元图标查看实际检测到的模型单价、核对日期和官方来源。52 项测试通过。

折合使用 2026-10-31 核对的标准短上下文公开价表，将选定历史按当前表重估，用于衡量用量价值；不代表历史账单、订阅实付或账号余额，不含加速、长上下文溢价、工具费、税费或货币换算。价格表随源码版本更新，应用不后台抓取价格。

Claude 缓存写入优先读取日志中 5 分钟／1 小时的分类，已知的 1 小时写入按对应费率计算；缺少时长时按 5 分钟写入折合并注明假设。Codex 未提供缓存写入时长时采用 30 分钟参考费率。缓存长时分类属于已有写入量的子集，不额外增加 Token；推理 Token 仍包含在输出中。

只匹配已核对的模型 ID 或对应日期快照；内部模型、第三方模型及未知名称不猜价。部分记录无法定价时，显示「部分折合」及未定价 Token 数；全部未知时显示「未定价」，不显示为零费用。无本机日志的服务商不显示零金额。金额先用 Decimal 汇总，最后显示到美分；小于一美分显示 `< US$0.01`。原始 Token 和 Token CSV 保持精确整数。

价格来源：[OpenAI 定价](https://developers.openai.com/api/docs/pricing)、[GPT-6 Sol](https://developers.openai.com/api/docs/models/compare?model=gpt-6-sol)、[GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4)、[GPT-5.2](https://developers.openai.com/api/docs/models/gpt-5.2)、[GPT-5.1 Codex](https://developers.openai.com/api/docs/models/gpt-5.1-codex)、[Claude 定价](https://platform.claude.com/docs/en/about-claude/pricing)。

0.5.0：增加原生 WidgetKit 桌面／通知中心小组件，包含小号用量卡片和中号用量＋近 7 天折线图。可在编辑小组件时选择今日、近 7 天或近 30 天；点击打开主应用的对应统计范围。新增 Xcode 工程与组件构建脚本，41 项测试通过。

**当前本机验收边界：** 扩展已构建、注册并在系统 WidgetKit Simulator 中加载；小、中尺寸布局已渲染检查。主应用可写入摘要，但本机没有 Apple 开发者签名证书，系统实际拒绝临时签名扩展读取 App Group 文件。因此当前本地包只能预览布局，桌面真实数据显示尚需完成签名，不能视作已通过端到端验收。组件会明确显示签名／共享权限问题。

## macOS 小组件

主应用每分钟扫描本机日志，向 App Group 原子写入摘要；只包含服务名、总 Token、每日数值、API 折合摘要、日期与可用额度百分比，不包含登录令牌、请求 ID、日志路径、模型名或对话内容。组件不扫描日志、不读取凭据、不请求服务商。主应用保持运行时定期请求组件重载；组件请求约 15 分钟后刷新，具体时间由 macOS 决定。跨天后旧的相对时间统计隐藏并提示待更新，过期摘要保留上次更新时间。

完成签名后，将包含扩展的应用移入「应用程序」并至少打开一次，再右键桌面 → 编辑小组件 → 搜索 QuotaBar。选择小号或中号添加；右键组件 → 编辑可切换统计范围。设置里的「同步统计摘要」可写入最新数据并请求重载。

```sh
# 本机临时签名构建：用于编译与界面预览，不保证共享容器访问
bash scripts/build-widget-app.sh
open dist/QuotaBar-Widgets.app
```

生成 `dist/QuotaBar-Widgets.app` 和通用架构 ZIP。Xcode 工程已提交，可直接打开 `QuotaBar.xcodeproj`；只有修改 `project.yml` 时才需要运行 `xcodegen generate`。

运行时请将 ZIP 解压到本机非同步目录，例如 `~/Applications`。本项目所在 Documents 目录会被文件同步服务附加 Finder 元数据，实测会使嵌入扩展的严格签名校验失败；ZIP 中的干净构建已通过校验。也可设置 `QUOTABAR_APP_OUTPUT="$HOME/Applications/QuotaBar.app"`，让构建脚本直接输出到非同步目录。

要启用共享数据，先在 Xcode → Settings → Accounts 登录 Apple ID，并在 Manage Certificates 中建立有效 Apple Development 或 Developer ID 签名证书。以下两个变量必须替换为实际证书名与实际 Team ID；macOS 专用 App Group 使用签名团队前缀，主应用与组件的值必须一致：

```sh
QUOTABAR_SIGN_IDENTITY='实际的 Apple Development 或 Developer ID Application 证书名称' \
QUOTABAR_APP_GROUP='实际TEAMID.dev.quotabar.shared' \
bash scripts/build-widget-app.sh
```

脚本会验证签名团队与 App Group 前缀。若从 Xcode 构建，在两个应用目标使用同一团队及有效签名身份，并将 `QUOTABAR_APP_GROUP` 改为实际团队前缀。`group.` 前缀方案还涉及开发者后台 App Group 注册及 provisioning profile，当前脚本采用 macOS 团队前缀方式。

主应用 `--check-widget` 只验证应用端摘要读写；组件端仍需在系统 WidgetKit Simulator 或桌面验证，不能把该命令的成功视为跨进程读取成功。未配置签名时显示权限提示，不用演示数字替代真实统计。

Apple 参考：[创建组件扩展](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)、[App Group 容器与 macOS 签名条件](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)、[组件时间线与刷新](https://developer.apple.com/documentation/widgetkit/timeline)。

0.4.0：Token 页点击「趋势」查看 Claude / Codex 双折线，可切换总 Token 或仅输出，悬停显示相应时段的具体数量。今日按小时，7 / 30 天按天；全部历史超过一年时按月聚合。另含两家合计的时段平均值、峰值及输入／输出／缓存读／缓存写构成条。窗口保持 360 × 480，点击「概览」返回紧凑卡片。36 项测试通过，包含分时边界、补零、未来记录过滤、长历史聚合和图表与概览总量一致性。

趋势的零值只表示本机没有对应记录，不代表账号当时没有使用。平均值包含零记录时段与未结束的当前时段。构成条始终显示区间全部 Token；「仅输出」只切换折线及对应均值、峰值。图表使用与概览相同的已去重记录，不额外查询服务商，也不估算未记录用量。

0.3.0：窗口从 420 × 700 缩小到 360 × 480，默认显示紧凑概览。数字使用中文「万／亿」单位，四舍五入到两位小数；小于一万保持精确整数。例如 209,758,837 显示为 2.10 亿、910,652 显示为 91.07 万。鼠标悬停可看精确值，点击「查看明细」可展开精确合计、模型统计和日志信息；CSV 仍导出精确整数。31 项测试通过。

0.2.2：在已挂载的原生窗口中移除滚动条控件，修复系统「始终显示滚动条」时 SwiftUI 隐藏设置失效的问题。保留滚轮和触控板滚动，不改变 macOS 全局设置。自检在实际窗口中检查滚动前后的控件状态；预览也改为渲染实际窗口，避免离屏视图漏掉原生控件。

## 具体 Token 用量（0.2.0）

启动后默认进入「Token 用量」，选择今日、近 7 天、近 30 天或全部，使用万／亿简写，悬停或展开查看精确整数，支持按模型汇总和导出 Token CSV。近 7 天指本地日期的今天及之前 6 天，不等同于服务商的订阅额度周。

- **Claude Code**：读取本机 `~/.claude/projects/**/*.jsonl` 的 assistant usage 元数据，包含子代理记录。
- **Codex**：读取本机 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/**/*.jsonl` 的 token_count 元数据，覆盖写入这些目录的桌面版及 CLI 会话。
- 同时尊重启动环境的 `CLAUDE_CONFIG_DIR` / `CODEX_HOME`。这是本机已保存记录的统计，可能包含过去切换过的账号，不是当前登录账号的跨设备账单。不含未保存到上述日志的网页、手机或其他设备用量。
- Token 页面无需先连接订阅额度 API。启动时读取已有历史，此后每分钟增量扫描；不需要从安装之日重新积累。

**总计 = 普通输入 + 输出 + 缓存读取 + 缓存写入。** Claude 的 input_tokens 本身不含缓存，直接分项相加；Codex 的 input_tokens 已含缓存，先拆出缓存再相加。推理 token 属于输出的子集，不重复添加。缓存读取也会计入总 token，数字可能很大，不代表同等金额或同等额度消耗。

Claude 流式日志按 message ID + request ID 去重并取最终计数，Codex 按累计计数和 turn ID 去重，避免重复的限流更新、复制日志及分叉聊天的共享前缀重复计数。缺失最后一次计数的旧 Codex 记录使用累计值差额。扫描按文件偏移增量读取，识别截断与文件替换；尚未写完的一行等完成后再统计。无法读取或格式异常的记录会显示统计不完整。

仅提取 token 数、模型和时间等用量元数据。不将对话正文解码到应用数据模型，不记录或上传正文；用量索引只留在内存中。Token CSV 按本地日期、服务商和模型汇总，不包含会话内容或请求 ID。

本地验收使用独立脚本核对了两家日志的聚合结果；正在使用中的会话会继续增加 Token。仓库只包含源码与测试，不包含本机日志、个人用量历史或登录凭据。

## 开始使用

本机已构建的应用位于 `dist/QuotaBar.app`，双击即可启动。菜单栏出现仪表图标，点击查看额度；右键可以刷新或退出。可将应用拖入「应用程序」后在设置中开启登录启动。

- **Codex**：自动发现本机 Codex CLI 并复用登录。找不到时，在设置里指定可执行文件路径。先在终端执行 `codex login` 完成订阅账号登录。
- **Claude**：点击「连接 Claude」，复用 Claude Code 的登录状态。macOS 可能请求读取「Claude Code-credentials」钥匙串项目；允许后才能查询。若登录需要更新，点击「修复 Claude 登录…」，等待官方 CLI 的 `/usage` 面板出现，再回到 QuotaBar 刷新；只有 CLI 自己也无法续期时才需要 `/login`。首次可能提示信任应用自身的 Resources 目录，它只包含此应用的登录修复脚本。仅登录 Claude 桌面版还不够，需要 Claude Code 的订阅登录。
- **API key 账号**：当前版本显示订阅额度，不计算 API 账单或 token 花费。

本机验证：Codex 查询成功；Claude 由官方 CLI 自动续期后查询成功，返回五小时及每周两个额度窗口。

## 功能

- 菜单栏 `CL` / `CX` 显示服务商返回的所有额度窗口中，最低的剩余百分比。
- 额度卡片显示已用、剩余、重置倒计时及最后成功查询时间。
- 按实际返回值展示五小时、每周以及附加模型额度；不存在的窗口不显示。
- 1 / 5 / 15 分钟自动刷新，默认 5 分钟；支持手动刷新和唤醒后检查。
- 查询失败保留上次数据并标记过期；已经到期的窗口不会被本地猜成 0% 已用。
- 429 遵守 `Retry-After`；其他失败使用退避，快速连续点击不会重复发送请求。
- 可固定悬浮窗，支持系统深浅色、登录启动。
- 本地保存最近 30 天的额度快照，显示最近 24 小时的首个窗口趋势，可导出 CSV 或清除历史。

「订阅额度」页的趋势是定时采样的**额度百分比**；「Token 用量」页读取本机日志的具体 token 值。额度百分比不能换算为固定的剩余 token、消息数或实际费用。关闭应用期间不会采样额度百分比，但本机新产生的 token 日志会在下次打开时补入。服务商不同窗口和不同模型的额度百分比不能相加。

## 数据来源与边界

Codex 使用官方 [app-server 协议](https://learn.chatgpt.com/docs/app-server) 的 `initialize` → `initialized` → `account/rateLimits/read`。每次查询启动短时只读连接，不调用 `thread/start` / `turn/start`，不消耗模型推理额度。CLI 内部可能更新自己的认证缓存或运行日志。

Claude 使用本机 Claude Code 登录，通过 `https://api.anthropic.com/api/oauth/usage` 查询。认证结构和端点已与本机安装的 Claude Code 客户端核对，但它属于内部客户端接口，并非稳定的公共第三方额度 API，可能变更或拒绝请求。失败会明确显示，不用 token 记录估算订阅额度。

Claude 官方说明：[订阅用量窗口](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)、[Claude Code 凭据存储](https://code.claude.com/docs/en/authentication#credential-management)。Claude 各产品的订阅额度共用。

QuotaBar 只在内存中使用 Claude access token，固定向 Anthropic 发请求，拒绝 HTTP 重定向；不复制 Claude 的凭据、不读取浏览器 Cookie、不提取对话正文。「修复 Claude 登录」打开官方 CLI，由 CLI 自己处理凭据续期，不发起模型对话。后台查询不会主动弹钥匙串授权，首次授权由「连接 Claude」触发。

0.1.1 修复：以服务端 401 判定登录失效，不因本地到期时间直接阻断查询；过期钥匙串记录不会遮蔽更新的 fallback 文件；手动连接可以绕过普通失败退避，仍遵守服务端 429 的等待时间。

本地历史存储于 `~/Library/Application Support/QuotaBar/usage-history.json`，仅包含服务名、额度窗口、百分比、重置时间和采样时间；无令牌、邮箱或对话内容。上限 20,000 条；文件权限 `0600`。设置保存在 macOS UserDefaults。

## 构建与测试

需要 Xcode / Swift 6。源码兼容 Swift 5 语言模式。

```sh
bash scripts/build-app.sh
open dist/QuotaBar.app
```

```sh
swift test --disable-sandbox --build-system native --manifest-cache local
```

构建脚本使用 SwiftPM native build system，避免当前 Xcode swiftbuild 的 dSYM 步骤在受限环境中失败。`--disable-sandbox` 关闭的是 SwiftPM 自身嵌套构建沙盒。测试包含真实管道握手、查询超时终止、认证错误映射、两家格式解析、过期窗口、限流和历史保留边界。

```sh
# 只读诊断；不输出凭据，不发起模型对话
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-tokens
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-codex
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-claude
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-costs

# 独立演示模式，不查询真实账号、不写入真实历史
dist/QuotaBar.app/Contents/MacOS/QuotaBar --demo
```

SwiftPM 的 `build-app.sh` 只生成菜单栏应用，不嵌入 WidgetKit 扩展；包含组件的版本使用 `build-widget-app.sh` 或 Xcode 工程构建。菜单栏包为本机架构，组件包为 Intel + Apple Silicon 通用架构。面向他人分发前需要 Developer ID 签名与公证。
