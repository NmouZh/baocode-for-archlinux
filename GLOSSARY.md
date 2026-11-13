# 术语表（Glossary）

本文件定义 BaoCode Arch Linux 打包 fork 的领域词汇。英文是规范用词：issue 标题、commit、代码与测试名称优先使用英文词；中文是同一概念在中文文档里的对照译名。写出新概念前先查这里；如果词表没有它，先补词表再使用，不要临时发明近义词。相关架构决定见 [ADR-0001 镜像发布架构](docs/adr/0001-arch-mirror-releases.md) 与 [ADR-0002 Fork 保留自己的 workflow 文件](docs/adr/0002-workflow-files-stay-with-the-fork.md)。

| 英文规范用词 | 中文 | 定义（一句话） | 使用规则 |
| --- | --- | --- | --- |
| Upstream | 上游 | `baocode-dev/baocode` 官方仓库及其发布的 macOS、Windows、Debian 制品与应用内更新清单。 | 指官方仓库、官方 Release 或官方更新清单时用 Upstream；不要用 Upstream 指本 fork 的 Release 或我们自己的打包产物。 |
| Fork | 本 fork | `NmouZh/baocode-for-archlinux`，在上游代码之上增加 Arch Linux 打包、镜像发布与 pacman 更新的仓库。 | 指本仓库的自有改动、workflow 与发布时用 Fork；不要用 Fork 泛指上游，也不要把 fork 的产物称为 Upstream 产物。 |
| Mirror release | 镜像发布 | 本 fork 在 GitHub Releases 上创建、与上游某个 Release 同名 tag（`v<marketing>`）和同版本号的 Release，资产只包含四个 Arch 包。 | 默认只镜像上游最新 Release，不回填历史；显式指定旧 `version` 可创建旧版本 Release，但不得标为 latest。不要把它叫 “fork release” 或 “Arch release”。 |
| Source package | 源码包 | Arch 包 `baocode`：从本仓库固定合并提交（`_commit`）的 GitHub 归档构建，`pkgver` 可带领先提交后缀，构建时联网获取 Flutter 与 Rust，因此不发布到 AUR。 | 说包名时用代码格式 `baocode`；与 “upstream source tarball”（上游官方 Linux tarball）区分，后者只提供 `remote/` 文件。 |
| Binary package | 二进制包 | Arch 包 `baocode-bin`：用上游官方 Linux tarball 及其校验和构建的预编译包，`pkgver` 严格等于上游 Release 版本，可发布到 AUR。 | 说包名时用代码格式 `baocode-bin`；不要用 “binary” 单指源码包构建出的可执行文件。 |
| Sync | 同步 | 定时或手动 workflow 把上游 `main` 合入本 fork 的 `main` 并推送的步骤。 | Sync 只指代码合并，不指打包或发布（那是 Prepare 与 Publish）；合并冲突时开一个去重 issue（标签 `ready-for-human`）并让运行失败，不要强推或跳过。 |
| Update source | 更新源 | Linux 应用内更新检查所使用的数据来源，即本 fork 的 GitHub Releases 列表；macOS 与 Windows 仍使用上游签名清单。 | 讨论 Linux 更新时用 Update source，不要与上游 manifest URL 混用；`BAOCODE_UPDATE_URL` 覆盖仍优先于默认选择。 |
| Leading commits | 领先提交 | 本 fork 的源码提交（`_commit`，即合并提交）相对所基于的上游 Release tag 多出的提交数，编码进源码包的 `pkgver`。 | 只用它描述源码包的版本后缀；二进制包永远不携带领先提交信息。 |
| pkgver | 包版本 | Arch 包版本中由上游营销版本组成的部分：源码包为 `X.Y.Z`，领先上游 tag 时为 `X.Y.Z.rN.gSHA`；二进制包恒为 `X.Y.Z`。 | `pkgver` 不是应用版本（如 `pubspec.yaml` 的 `1.9.5+31`），也不是 pacman 显示的完整版本（那是 `pkgver-pkgrel`）；带 `.rN.gSHA` 的值不是语义版本，不要交给应用版本解析器。 |
| pkgrel | 包发布号 | Arch 包版本中连字符后的整数，仅打包内容变化时递增。 | 同一 `pkgver` 下重建（例如 `force_rebuild`）必须提高 `pkgrel`；仅 `pkgrel` 变化不触发应用内更新，这是已知范围之外的行为。 |

首个镜像发布的例子：上游最新 Release 为 `v1.9.5`，而本仓库 `main` 比该 tag 多 17 个提交，因此源码包是 `1.9.5.r17.g<短 SHA>`，二进制包是 `1.9.5`；两者都装到 `/opt/baocode`，互相 `provides`/`conflicts`，用户同时只能安装一个。