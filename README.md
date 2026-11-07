# MGUpd

使用 SwiftUI + AppKit 编写的原生 macOS GitHub Release 监测工具，管理界面参考工作区中的 MFan。支持 macOS 13+，无第三方依赖。

## 功能

- 菜单栏常驻图标与未读仓库数量；关闭管理窗口后继续监测，退出应用后停止。
- 概览、仓库管理、设置三个页面；添加、搜索、删除、暂停仓库，按仓库选择是否包含预发布版本。
- 接受 `owner/repo` 或 `https://github.com/owner/repo`。
- 手动检查或每 15 / 30 / 60 / 180 / 360 / 1440 分钟自动检查（默认 30 分钟）。睡眠期间不检查，唤醒后恢复。
- 首次成功检查仅建立基线，包括没有 Release 的仓库；之后按 Release ID 去重，显示未读状态、版本、发布时间及发布说明链接。
- 原生系统通知；每轮每个仓库最多通知一个最新发现版本，点击打开 GitHub Release。首次运行不会自行请求通知权限，请在设置中开启。
- 用户级 LaunchAgent 登录启动，与 MFan 使用相同机制，不需要管理员权限。
- 可选 GitHub Token 存入 macOS 钥匙串，不保存到 JSON 或显示明文。

## 构建与使用

需要安装 Xcode Command Line Tools 和 Swift 5.8+。在本目录运行：

```sh
swift test
sh scripts/build-app.sh
open dist/MGUpd.app
```

脚本生成针对当前机器架构的 `dist/MGUpd.app` 并做 ad-hoc 签名，不是 Developer ID 签名或公证发行包。建议先将应用复制到 `/Applications` 或 `~/Applications`，再打开并启用登录启动。移动应用后需重新开启登录启动，以更新路径。

请通过 `.app` 启动，不使用 `swift run` 验证通知：系统通知依赖正确的应用包身份。通知横幅、钥匙串授权和登录启动需要在本机交互验证；重建后的 ad-hoc 签名可能需要再次授权钥匙串。

首次打开后添加仓库，在设置中按需启用通知和登录启动。无需 Token 即可监测公开仓库。私有仓库需要有对应仓库读取权限的 Token（fine-grained token 至少授予目标仓库 Contents 只读权限）。

## 数据与行为

- 配置及监测状态：`~/Library/Application Support/MGUpd/state.json`，原子写入；读取损坏文件时不会覆盖原文件。
- 登录项：`~/Library/LaunchAgents/local.mgupd.MGUpd.login.plist`；关闭开关移除文件，下次登录生效。卸载前请先关闭该开关。
- Token：钥匙串服务 `MGUpd.GitHub`，账户 `access-token`；卸载前可在设置中删除。
- 无遥测。监测 API 禁止重定向；附件下载仅允许 HTTPS 的 GitHub 及明确列出的 GitHub 附件域，跨域重定向移除 Token，Token 仅发送给 `api.github.com`。
- 当前监测 Release，不监测 Commit 或仅有的 Git Tag。支持下载 Release 附件，绝不会自动安装或运行。
- 草稿被排除，版本按发布时间而非语义版本号排序。开启预发布后，之前未追踪的预发布可能作为新发现版本提醒。
- 每次检查分页读取 Release，最多 10 页、每页 100 条；超过上限显示错误而非使用不完整数据建立基线。
- GitHub 匿名请求通常限额为 60 次/小时，认证请求通常为 5000 次/小时（以 GitHub 实际策略为准）。多个仓库和分页会增加请求次数；建议添加 Token 或延长检查间隔。限额及网络错误显示在仓库卡片和状态栏中。

## Release 附件下载

- 在仓库管理卡片开启“自动下载新版本匹配附件”，**每仓库默认关闭**。文件名 pattern 每行一个，完整名称匹配、不区分大小写，`*` 匹配任意字符，`?` 匹配一个字符，反斜杠转义字面通配符。例如 `*macos*arm64*.dmg`；多行 OR 匹配并按附件 ID 去重，选中附件顺序下载。旧 substring 配置自动转成两端带 `*` 且转义字面通配符的规则。
- 无 pattern 时，只在 Release 恰有一个产物且名称明确包含 macOS/Darwin/OSX/Mac 和本机架构（arm64/aarch64、x86_64/amd64/x64）或 universal/universal2 时选择。通过 sysctl 识别真实硬件，包括 Rosetta；架构未知必须配置。多个产物严格要求 pattern，即使只有一个适合本机。计数排除 `.asc`、`.sig`、`.sha256`、`.sha512`、`.sha256sum`、`.sha512sum` 以及名称含 `checksums` 或以 `sha256sums`/`sha512sums` 开头的文件；显式 pattern 仍可选择这些文件。
- 卡片显示真实 URLSession 下载字节、总字节、整体百分比与完成附件数量。整体百分比按附件声明大小加权，包含已完成并跳过的附件；传输 100% 后仍需大小验证、隔离属性与原子保存，最终以“下载完成”为准。
- 自动下载仅由本轮新发现且为当前最新的 Release 触发。首次检查只建立基线；开启开关或修改规则不会回溯下载历史。可用“下载最新匹配附件 / 重试”手动下载已有最新版本，包括首次基线。
- 下载独立于检查任务。失败的最新版本在下一次成功检查时重试，最多自动尝试 3 次（包括首次，重启后仍累计）；达到上限后需手动重试。关闭自动开关、修改规则或暂停/删除仓库会取消任务和待重试记录；已经保存的附件不会删除。更新到其他最新版本会放弃旧版本待重试任务。
- 默认目录为 `~/Downloads/MGUpd/<owner>/<repo>/<releaseID>/`，卡片提供 Finder 入口。下载设置、待重试 ID、尝试次数及完成记录独立存于 `~/Library/Application Support/MGUpd/downloads.json`，不含 Token。记录损坏时保留原文件并禁用本次会话下载。
- 默认公开/私有附件均使用 GitHub asset API；私有附件需要设置有仓库读取权限的 Token。URLSession 流式写临时文件，验证 HTTP 200 与 GitHub 声明的附件大小，再设置 `com.apple.quarantine` 并在目标目录独占原子重命名。拒绝路径分隔符、控制字符、路径穿越与符号链接目录，不覆盖已有同名文件。大小验证不是数字签名或真实性验证，运行前仍应核实发布者。
- 若文件已存在但下载记录缺失（例如保存记录前退出），重试会报告冲突而不是覆盖。请先在 Finder 核实文件，必要时移走该文件再重试。下载会消耗网络流量和本地磁盘空间；大型附件落盘期间可能额外需要一份临时文件空间。

### 下载镜像

设置页面支持可选 HTTPS 镜像前缀，留空直连；拼接方式与 MTunl 相同：`https://mirror.example/https://github.com/owner/repo/releases/download/tag/file`。不得包含认证信息、查询参数或片段，保存校验错误显示在面板。配置独立存于 `downloads.mirror.json`；保存新配置会取消当前下载。

镜像仅用于**无 Token 的公开附件** browser download URL，API 元数据始终直连；只要存在 Token，所有附件（包括公开仓库）始终经 GitHub asset API 直连，私有附件不会发送到镜像。不向镜像发送 Token 或 Cookie。镜像重定向仅允许 HTTPS 同源或明确受信 GitHub 下载域。第三方可见下载 URL 与 IP，可能修改文件；大小校验不代表真实性，请只使用信任的服务并核实发布者签名。

## 结构

- `Sources/MGUpd/`：应用入口、管理界面、系统通知、钥匙串、登录启动及调度。
- `Sources/UpdateCore/`：GitHub API、仓库输入验证、Release 状态计算、JSON 持久化、独立下载管理器与安全附件传输。
- `Tests/UpdateCoreTests/`：基线、去重、预发布、输入验证、持久化、模拟网络分页及错误测试。
