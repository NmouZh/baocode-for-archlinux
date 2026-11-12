# ADR-0001: Arch 镜像发布架构

- 日期：2026-11-12
- 状态：Accepted
- 范围：本 fork 的 Arch Linux 打包、GitHub Release 镜像、AUR 发布与 Linux 应用内更新
- 词汇：见 [GLOSSARY.md](../../GLOSSARY.md)
- 格式：遵循 `docs/agents/domain.md` 的 ADR 约定

## Status

Accepted（已接受）。本 ADR 记录 issue #1 的架构决定，由 #2–#12 落地。后续实现或文档若与此冲突，必须在改动中显式指出（“与 ADR-0001 冲突，因为……”），并优先新增 ADR 来取代它，而不是静默偏离。

## Context

BaoCode 官方 Linux 只发布 Debian/Ubuntu `.deb`。Arch 用户没有 pacman/makepkg 可安装的包，也没有 AUR 包；从源码构建又需要精确的 Flutter 3.47.5、Rust 1.97.1 与 GTK 工具链，而 Arch 官方源没有对应 Flutter。应用内更新在 Linux 上只认 dpkg、`/opt/baocode` 与 pkexec，并从 `https://dl.baocode.dev/releases/latest.json` 读取只允许 `baocode.dev` 域名的 Ed25519 签名清单，因此在 Arch 上必然退化为手动更新。

本 fork 需要持续跟随上游、构建 Arch 包并提供可用的安装与更新路径，同时满足以下约束：

- 不自造版本号，不转发或重托管上游 Release 资产，不回填全部历史版本。
- 核心流水线只使用默认 `GITHUB_TOKEN`，不要求 PAT，不自建 Ed25519 签名密钥。
- 源码包内容必须与本仓库合并后的代码一致且可复现；二进制包快速路径与上游一致。
- fork 的 Actions 与定时 workflow 默认关闭，需要维护者首次在 Actions 页面启用。

起草时的事实基准：上游最新 Release 为 `v1.9.5`，本仓库 `main` 比该 tag 多 17 个提交，因此首个镜像的源码包版本将是 `1.9.5.r17.g<短 SHA>`，二进制包是 `1.9.5`。

## Decision

### 1. 镜像发布身份与每日同步

本 fork 暴露与上游相同的 tag（`v<marketing>`）和同版本（same version）的 GitHub Release。默认只镜像上游最新 Release，不回填历史；显式指定 `version` 可创建旧版本的 Mirror release，但不得把它标为 latest。应用更新器从 Release 列表中选择语义版本最高的非预发布版本，不依赖 latest 标记。

tag 名称与版本号和上游相同（same tag / same version），但 tag 指向本 fork 的打包提交，而不是上游的发布提交：

- 默认路径（定时或手动且未指定 `version`）：合并上游 `main` 后，源码包从该合并提交构建，随后在 `main` 上生成一个打包提交，更新 `pkgver`、`_commit` 与校验和；Release tag 指向这个打包提交。
- 显式 `version`：workflow 获取上游该版本 tag 对应的提交并从它构建；打包提交创建在该 tag 提交之上，Release tag 指向打包提交，`main` 不变。
- `force_rebuild`：`pkgrel` 加一，把 tag 移到新的打包提交，并覆盖既有 Release 资产。

同步（Sync）由每日（daily）定时 `schedule.cron` 与 `workflow_dispatch` 触发。sync 步骤合并上游 `main` 并推送，同时抓取 tags；合并冲突时开一个去重 issue（标签 `ready-for-human`）并让运行失败，绝不推送冲突状态。只有上游发布 Release 时才发布镜像（或维护者显式指定已存在的上游版本），fork 不自造版本。

发布资产只包含四个 Arch 包（源码/二进制 × x86_64/aarch64），不转发上游资产。Release 正文镜像上游 notes，并补充源提交、包清单、安装方法与上游 Release 链接。每次构建都上传 Actions artifact；publish 汇总可用产物，幂等地创建或更新 Release。job 链为 sync → prepare → build 矩阵 → publish → AUR；workflow 权限为 `contents: write` 与 `issues: write`，使用默认 `GITHUB_TOKEN`。校验和在 prepare 阶段计算并提交进 PKGBUILD：源码归档下载后计算 SHA-256；上游资产优先使用 GitHub 的 per-asset `digest`，缺失时下载计算。

### 2. 版本与领先提交编码

源码包的 `pkgver` 以上游营销版本为基础。当源码提交（即合并提交）领先于它所基于的上游 Release tag 时，追加 `.rN.gSHA`：

```
X.Y.Z.rN.gSHA
```

其中 `N` 是源码提交（`_commit`，即合并提交）相对上游 tag 多出的提交数（Leading commits），`SHA` 是该源码提交的短 SHA。例如上游为 `v1.9.5`、`main` 领先 17 个提交时，源码包为 `1.9.5.r17.g<短 SHA>`。二进制包的 `pkgver` 永远是上游 Release 的 `X.Y.Z`，不携带 `.rN.gSHA` 后缀，因为它的内容来自上游官方 tarball。

`pkgrel` 是 Arch 的打包发布号，仅在打包内容变化时递增；`force_rebuild` 在同一 `pkgver` 上把 `pkgrel` 加一，移动 tag 并覆盖 Release 资产。`pkgver`（尤其带 `.rN.gSHA` 的值）不是应用版本，也不是语义版本；应用内更新器使用自己的版本解析与选择逻辑，仅在 `pkgrel` 级重建不触发应用内更新（范围之外）。

### 3. 两包拆分与互斥

拆成两个包，各自有独立目录与 PKGBUILD：

- **Source package `baocode`**：源码来自本仓库在固定合并提交（`_commit`）上的 GitHub 归档，并额外使用上游同版本 Linux tarball，仅用于安装 `remote/VERSION` 与 `remote/servers.json`。它在 `prepare()`/`build()` 中联网获取 Flutter 3.47.5（x86_64 用官方 tarball，aarch64 用 git clone 到该 tag）与 rustup/Rust 1.97.1。它可用，但联网构建与特定 Flutter 版本不满足 AUR 规则，因此不发布到 AUR。
- **Binary package `baocode-bin`**：`source` 是上游官方 `linux-amd64`/`linux-arm64` tarball 及其校验和，符合 AUR 规则，是快速路径。

两包都声明 `license=('GPL-3.0-only')`、`arch=('x86_64' 'aarch64')`、`options=(!strip !debug)`，运行时依赖 glibc、GTK3、xz（liblzma）、util-linux（libblkid）与 bash；都装到 `/opt/baocode`，写 `/usr/bin/baocode` 包装脚本、桌面项和 128px 图标。

两包互斥：`baocode-bin` 声明 `provides=('baocode')` 与 `conflicts=('baocode')`，`baocode` 反向声明 `conflicts=('baocode-bin')`。两者安装相同的应用文件，必须保证 pacman 与 AUR helper 不会同时安装两个。

构建矩阵在官方 Arch 容器中构建 x86_64，在 ARM runner 上的 Arch Linux ARM 容器中构建 aarch64，`makepkg` 以非 root 的 builder 用户运行。aarch64 源码包这条腿不阻塞发布，仓库变量可关闭它。

AUR 部分：本仓库提交二进制包的 AUR 版 PKGBUILD 与生成的 `.SRCINFO`，并用 `makepkg --printsrcinfo` 校验二者一致，防止 AUR 仓库漂移。配置了 AUR SSH 私钥 secret 时，workflow 推送它们到 `baocode-bin` 的 AUR 仓库；未配置时跳过。AUR 包必须先在网页创建，这一步与公钥配置是一次性人工操作。

### 4. Linux 更新源与信任模型（Trust model）

Linux 的应用内更新源（Update source）是本 fork 的 GitHub Releases 列表，选择语义版本最高的非预发布版本，不依赖 latest 标记。通过 pacman 对应用可执行文件的所有权查询（如 `pacman -Qoq /opt/baocode/baocode`）判断当前安装的是 `baocode` 还是 `baocode-bin`，据此选择对应资产；架构映射到 `x86_64` 或 `aarch64`。下载按文件大小与 GitHub 资产的 SHA-256 `digest` 校验。网络直连优先，失败后对 API 与资产下载都加上 `https://gh-proxy.com/` 前缀回退（例如 `https://gh-proxy.com/https://api.github.com/...`）；两者都失败则表现为正常的更新检查失败。

安装使用 `pkexec pacman -U --noconfirm`，应用退出后重新启动，包仍归 pacman 管理。若应用不是 pacman 安装或 pkexec 不可用，则报告需要手动更新，并链接到本 fork 的 Releases。实现复用现有 `UpdateService`、`UpdateController`、更新 UI 与设置；新增的 GitHub 后端把 Release 数据合成为现有清单形状，签名校验仅对该来源可选。

**信任模型切换。** Arch 更新源不再使用上游的 Ed25519 清单签名。upstream 的 Ed25519 签名只覆盖上游自己的 `latest.json` 与资产，无法为我们的 Arch 包签名，也无法在 pacman 安装路径上生效；为 Arch 更新源自建 Ed25519 签名密钥明确不在范围内。作为替代，Arch 路径信任：

1. **本 fork 的 GitHub 仓库与维护者账号**：Release 由 workflow 使用仓库的 `GITHUB_TOKEN`（权限 `contents: write`、`issues: write`）创建和更新，只有上游发布或维护者显式触发才会产生 Mirror release。
2. **GitHub 元数据中的 SHA-256 digest**：下载器校验资产大小与 GitHub API 返回的 per-asset `digest`，损坏、截断或与元数据不符的下载会被拒绝。
3. **HTTPS 传输**：直连时信任 `api.github.com`/`github.com` 的 TLS；回退到 `gh-proxy.com` 时额外信任该第三方代理的 TLS 终结与响应。
4. **pacman 与 pkexec 授权**：用户在一次提权提示后由 pacman 安装包，包仍受 pacman 数据库管理。

这个模型明确弱于上游的 Ed25519 签名：它不提供独立于 GitHub 的密码学签名。威胁与限制包括：fork 的 GitHub 账号或 token 被攻破、GitHub 自身或 Release 元数据被篡改；走 `gh-proxy.com` 时，代理若恶意可同时替换资产与其 digest，因为 digest 与该资产来自同一信任源。SHA-256 校验能发现传输损坏、截断与元数据不匹配，但不能证明发布者身份独立于 GitHub。

接受的补偿控制：流水线只用最小权限的 `GITHUB_TOKEN`；PKGBUILD 的校验和来自 GitHub digest 或构建时下载计算；源码包固定到 `_commit`，构建内容与本仓库合并提交一致；tag 名与版本号同上游一致，用户可直接对照；保留手动下载兜底，用户可以自行检查包。macOS 与 Windows 保持现有签名清单行为不变；默认上游清单仍强制 Ed25519 签名，签名校验仅对这个 GitHub 来源可省略。`BAOCODE_UPDATE_URL` 环境变量覆盖继续有效并优先。

### 5. Alternatives considered（替代方案）

- **继续只提供 Debian `.deb`，让 Arch 用户自行构建**：拒绝。没有 pacman/makepkg 可安装包，且 Flutter 3.47.5、Rust 1.97.1 与 GTK 工具链门槛过高，无法满足用户故事 1–2。
- **把源码包发布到 AUR**：拒绝。源码包在构建时联网获取 Flutter 与 rustup，并且依赖官方源没有的 Flutter 版本，违反 AUR 的构建时无网络规则，也不可复现。
- **继续使用上游 Ed25519 签名的更新源**：不可行。上游只发布 `.deb` 与受 `baocode.dev` 域名限制的清单，Arch 包不在其中，且路径依赖 dpkg；自建签名密钥被明确列为范围之外。
- **重托管或转发上游 Release 资产**：拒绝。范围之外，带来维护与带宽成本；二进制包改为在构建时直接使用上游官方 tarball。
- **回填全部历史 Release**：拒绝。成本高且无用户需求；显式 `version` 允许在需要时创建单个旧版本 Mirror release，但不得标为 latest。
- **每次上游提交都发布新版本**：拒绝。fork 会自造版本号，用户无法与上游对照。领先提交仅通过 `.rN.gSHA` 后缀体现，发布仍以上游 Release 为触发。
- **只做一个包（源码包）**：拒绝。无法为赶时间的用户提供免工具链的快速路径；二进制包也是 AUR 唯一可接受的形态。
- **AUR 推送时不把 PKGBUILD/.SRCINFO 提交进本仓库**：拒绝。自动化不可用时没有手动发布兜底，且无法在 CI 中校验 `.SRCINFO` 与 PKGBUILD 一致。
- **用 QEMU 或交叉编译代替 ARM runner 构建 aarch64**：拒绝。速度与可靠性更差，且难以真实模拟 makepkg 与运行时依赖；aarch64 源码包失败不阻塞发布，已限制其影响。

## Consequences

**正面影响**

- Arch 用户可以用 `makepkg -si` 安装源码包，或安装预编译的 `baocode-bin`，无需 Debian 包或本地 Flutter 工具链。
- `baocode-bin` 可进入 AUR，并在配置 secret 后随 Mirror release 自动更新。
- 两包互斥，用户不会误装两个；桌面项、图标、运行时依赖与 `/opt/baocode` 布局一致。
- 应用内更新固定在 Linux 上检查本 fork 的 GitHub Releases，用 `pacman -U` 在一次授权提示后完成更新，包仍归 pacman 管理。
- fork 每日跟随上游 `main`，冲突通过去重 issue 通知维护者；镜像 tag/版本与上游一致，便于对照。
- 流水线只需要 `GITHUB_TOKEN`；没有 PAT 与签名密钥的额外配置。每次构建都有 Actions artifact，发布幂等。

**代价与限制**

- Arch 更新路径的信任从上游 Ed25519 签名转移到 GitHub 账号、GitHub 元数据 digest 与 HTTPS/代理；详见第 4 节。能检测损坏，但不能提供独立于 GitHub 的发布者证明。
- 源码包构建昂贵且依赖网络与固定 Flutter 版本；aarch64 源码包可能失败且不阻塞发布，ARM 用户可能只拿到 `baocode-bin`。
- 不转发上游资产、不回填历史、不自造版本；镜像发布只跟随上游 Release。默认只服务最新版本，旧版本需显式触发。
- `pkgrel` 级重建不会触发应用内更新，这是明确的非目标。
- AUR 包需先人工在网页创建并配置 SSH 公钥；未配置 secret 时推送 job 跳过。
- fork 的 Actions 与定时 workflow 首次需要维护者在 Actions 页面手动启用；本机对 GitHub 域名的访问可能需要 `gh-proxy.com` 等备用通路。
- 已知风险：Arch 滚动源的 clang 可能触发上游 `-Werror`；aarch64 Flutter SDK 依赖 git clone；容器镜像与 runner 的磁盘/时间限制。