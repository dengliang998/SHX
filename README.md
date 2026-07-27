# KiteShell

KiteShell 是一个仅面向 macOS、以 SwiftUI 与 AppKit 为基础的原生远程服务器管理客户端。

当前版本已经实现主要的日常服务器管理流程：

- 连接中心、搜索、收藏、持久化分组、快速连接和新建连接
- FinalShell JSON 连接及加密密码导入，密码解析后转存本地加密凭据库
- 多会话标签与状态
- 基于 SwiftTerm、PTY 与系统 OpenSSH 的真实交互终端
- 真实 Linux CPU、内存、磁盘、网络和进程监控
- SFTP 远程文件浏览、上传、下载、内置/外部编辑、冲突保护与跨会话传输中心
- 工作区专注模式、键盘菜单和 VoiceOver 标签
- 本地加密凭据库、OpenSSH 主机密钥保护、连接诊断和配置导入导出
- 全局/连接命令脚本库、端口转发、跳板机、上游代理和工作区恢复

所有服务器指标、远程目录和连接状态均来自真实 SSH 会话，不创建示例或推测数据。SSH 认证由系统 `/usr/bin/ssh` 处理，可使用密码、指定私钥、SSH Agent 和跳板机；密码保存在当前用户的本地 AES-GCM 加密凭据库，应用不调用系统钥匙串，也不记录终端内容。

## 构建

安装完整 Xcode 后，可以直接用 Xcode 打开 `Package.swift` 并运行 `RemoteHub` scheme。

使用命令行验证：

```bash
swift build
swift run KiteShell
```

可使用本机固定开发签名身份生成 `.app`；若证书不存在，脚本会明确警告并回退为 ad-hoc：

```bash
./Scripts/build-app.sh
open .build/KiteShell.app
```

运行 `swift test` 和 `./Scripts/run-self-tests.sh` 可验证模型、导入导出、SFTP 命令安全转义、终端目录联动和编辑回传等核心逻辑。

最低目标为 macOS 14，首版仅支持 Apple Silicon。
