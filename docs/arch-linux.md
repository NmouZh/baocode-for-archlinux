# Arch Linux

本 fork（[`NmouZh/baocode-for-archlinux`](https://github.com/NmouZh/baocode-for-archlinux)）为 Arch Linux 提供两个包，并把 Linux 的应用内更新接到本 fork 的 GitHub Releases。领域词汇（Upstream、Fork、Mirror release、Source package、Binary package、Update source 等）见 [GLOSSARY.md](../GLOSSARY.md)；架构决定与信任模型见 [ADR-0001](adr/0001-arch-mirror-releases.md)。通用更新机制见 [auto-update.md](auto-update.md)，上游发版流程见 [release.md](release.md)。

- **二进制包 `baocode-bin`**：预编译包，内容来自上游官方 Linux tarball，符合 AUR 规则，是免工具链的快速路径。
- **源码包 `baocode`**：从本 fork 的固定合并提交构建，`pkgver` 可带 `.rN.gSHA` 后缀；构建时联网获取 Flutter 与 Rust，因此不发布到 AUR。
- 两包都声明 `arch=('x86_64' 'aarch64')`，都安装到 `/opt/baocode`，互相冲突，同一时间只能装一个。

## 安装

### 从 Releases 安装（baocode-bin）

本 fork 的 Mirror release 只包含四个 Arch 包（源码/二进制 × x86_64/aarch64），不转发上游资产。下载页面是 [本 fork 的 Releases](https://github.com/NmouZh/baocode-for-archlinux/releases)。

x86_64 用预编译包：

```sh
sudo pacman -U baocode-bin-1.9.5-1-x86_64.pkg.tar.zst
```

aarch64 换成对应资产：

```sh
sudo pacman -U baocode-bin-1.9.5-1-aarch64.pkg.tar.zst
```

`1.9.5` 与 `1` 是当前 PKGBUILD 的 `pkgver` 与 `pkgrel`；资产名规则是 `<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst`，版本更新后按 Release 中的实际文件名替换。Release 正文也给出同一条 `sudo pacman -U ...` 安装命令。源码包对应的是 `baocode-1.9.5.r17.g54ebc20-1-x86_64.pkg.tar.zst`（aarch64 为 `baocode-1.9.5.r17.g54ebc20-1-aarch64.pkg.tar.zst`）；一般不需要手动指定它，见下节。

### 从 AUR 安装（baocode-bin，发布后）

AUR 包名与二进制包相同：

```sh
yay -S baocode-bin
```

AUR 包必须先在 aur.archlinux.org 网页上创建，并且仓库配置了 `AUR_SSH_PRIVATE_KEY` 之后，workflow 才会自动推送更新（见[维护者操作](#维护者操作)）。在首次接入完成前，AUR 上可能还没有这个包，此时用上面的 Releases 包。

### 源码包（baocode）

克隆本 fork 后，在源码包目录构建并安装：

```sh
cd packaging/baocode
makepkg -si
```

`makepkg -si` 会按 PKGBUILD 安装 `depends=('glibc' 'gtk3' 'xz' 'util-linux' 'bash')` 和 `makedepends=('clang' 'cmake' 'ninja' 'curl' 'git' 'unzip' 'zip')`。构建过程需要联网：

- **Flutter 3.47.5**：x86_64 下载官方 stable tarball（`_flutter_version=3.47.5`）；aarch64 没有官方 SDK 归档，改为在 `3.47.5` tag 上 `git clone` Flutter。
- **Rust 1.97.1**：通过 `https://sh.rustup.rs` 安装 rustup，再按 `packages/bao_iroh/rust/rust-toolchain.toml` 的 `channel = "1.97.1"` 安装工具链。

源码包还会从上游同版本 tarball（x86_64 为 `BaoCode-1.9.5-linux-amd64.tar.gz`，aarch64 为 `BaoCode-1.9.5-linux-arm64.tar.gz`）取 `remote/VERSION` 和 `remote/servers.json`；这些文件只用于 SSH 远程功能。

这条构建路径**很慢**（workflow 给源码包 job 的上限是 360 分钟），且依赖精确的 Flutter/Rust 版本。它**不发布到 AUR**：AUR 要求构建时无网络，而这里在 `prepare()`/`build()` 中联网下载工具链，且 Arch 官方源没有 Flutter 3.47.5。网络受限时见[用代理构建](#用代理构建makepkg)。

### 两个包互斥、两种架构

- `baocode-bin` 声明 `provides=('baocode')` 与 `conflicts=('baocode')`。
- `baocode` 反向声明 `conflicts=('baocode-bin')`。

两者安装同一组文件：`/opt/baocode/baocode`、包装脚本 `/usr/bin/baocode`、桌面项 `/usr/share/applications/baocode.desktop`、图标 `/usr/share/icons/hicolor/128x128/apps/baocode.png`。因此 pacman 和 AUR helper 不会允许同时安装两个；换包时先卸载已装的那个。

架构写成 `arch=('x86_64' 'aarch64')`。x86_64 资产以 `-x86_64.pkg.tar.zst` 结尾，aarch64 资产以 `-aarch64.pkg.tar.zst` 结尾（aarch64 包在 Arch Linux ARM 容器中构建）。aarch64 的源码包构建允许失败且不阻塞发布，ARM 用户可能只拿到 `baocode-bin`。

`pkgver` 的含义：二进制包永远等于上游 Release 的营销版本（如 `1.9.5`）；源码包在合并提交领先上游 `v1.9.5` tag 时追加 `.r<N>.g<短 SHA>`（当前为 `1.9.5.r17.g54ebc20`，即领先 17 个提交）。`pkgrel` 只在打包内容变化时递增，`force_rebuild` 会把它加一。

## 应用内更新

Linux 的更新源是本 fork 的 GitHub Releases，而不是上游的 `https://dl.baocode.dev/releases/latest.json`：

- **Release 列表**：`https://api.github.com/repos/NmouZh/baocode-for-archlinux/releases`（后端请求时附加 `?per_page=20`）；API 请求同样先直连，网络失败、5xx 或返回的不是 JSON 时经 `https://gh-proxy.com/` 重试，4xx 不重试。内容解析成功后的语义问题（没有稳定版本、缺少对应资产等）不会重试，因为换路由拿到的内容相同。
- **版本选择**：取语义版本最高的非 draft、非 prerelease Release，不依赖 GitHub 的 latest 标记；显式镜像的旧版本 Release 不会变成更新。
- **包识别**：用 `pacman -Qoq /opt/baocode/baocode` 查询可执行文件归属。输出 `baocode` 或 `baocode-bin`，据此选择同名包的资产；架构映射为 `x86_64` 或 `aarch64`。
- **资产名**：与安装包一致，例如 `baocode-bin-1.9.5-1-x86_64.pkg.tar.zst`、`baocode-bin-1.9.5-1-aarch64.pkg.tar.zst`、`baocode-1.9.5.r17.g54ebc20-1-x86_64.pkg.tar.zst`、`baocode-1.9.5.r17.g54ebc20-1-aarch64.pkg.tar.zst`。
- **下载**：先直连；网络错误、5xx 或校验失败（大小或 SHA-256 不符）时对同一 URL 加 `https://gh-proxy.com/` 前缀重试，4xx 不重试。每次尝试都重写 `.part` 文件；下载按 GitHub API 给出的资产大小与 `sha256:<hex>` digest 校验，两条路由都不通过时拒绝安装。
- **安装**：校验通过后，安装脚本先执行 `pkexec pacman -U --noconfirm <下载的包>`（应用仍在运行，pkexec 在前台询问密码），然后等应用退出并重新启动它。包仍归 pacman 管理；安装脚本日志在数据目录的 `updates/install.log`。

`update.mode`（自动/手动/关闭）与其它平台共用，机制见 [auto-update.md](auto-update.md)。

### 手动兜底与 BAOCODE_UPDATE_URL

以下情况应用不会自动安装，而是在设置 → 更新中提示需要手动更新，并提供“打开下载页”，指向 [本 fork 的 Releases](https://github.com/NmouZh/baocode-for-archlinux/releases)：

- `pacman -Qoq /opt/baocode/baocode` 显示它不属于 `baocode` 或 `baocode-bin`（例如从 tarball 解压运行，或系统里没有 pacman）。
- 下载到的包名与 pacman 报告的包名不一致。
- 系统里没有 `/usr/bin/pkexec`。

手动更新时，按架构和已装包下载对应资产，再执行 `sudo pacman -U <文件>`。

`BAOCODE_UPDATE_URL` 覆盖仍然有效且优先：在 Linux 上设为非空值后，应用改用该 URL 指向的清单，不再走 fork Releases 后端；清单同源的下载链接也会被接受，便于发布前本地验证。设置该变量时 debug 构建也会启用更新。未设置覆盖时，Linux 使用 fork Releases；macOS 与 Windows 仍使用上游签名清单。

## 信任模型

Arch 更新**不使用**上游的 Ed25519 清单签名。上游签名只覆盖它自己的 `latest.json` 与资产，不能为 fork 的 Arch 包签名，本轮也不自建 Ed25519 签名密钥。

Arch 路径的信任来自：

1. **本 fork 的 GitHub 仓库与维护者账号**：Release 由 `.github/workflows/arch-mirror.yml` 使用仓库的 `GITHUB_TOKEN`（权限 `contents: write`、`issues: write`）创建和更新。
2. **GitHub 元数据中的 per-asset SHA-256 digest 与文件大小**：下载被截断、损坏或与元数据不符时会被拒绝。`UpdateUrlPolicy.githubReleases` 对该来源设置 `requiresSignature: false`；清单里如果带签名，仍会校验。
3. **HTTPS**：直连时信任 `api.github.com` 与 `github.com` 的 TLS；回退到 `gh-proxy.com` 时还信任该第三方代理的 TLS 终结与响应。
4. **pacman 与 pkexec 授权**：用户在一次提权提示后由 pacman 安装，包仍在 pacman 数据库中管理。

这个模型明确弱于上游 Ed25519：它不提供独立于 GitHub 的发布者密码学证明。若本 fork 的账号或 token 被攻破、GitHub 自身或 Release 元数据被篡改，digest 也可能被一起替换；走 `gh-proxy.com` 时，恶意代理同样能同时替换资产与其 digest。SHA-256 校验能发现传输损坏、截断和元数据不匹配，但不能证明发布者身份独立于 GitHub。完整分析、威胁与补偿控制见 [ADR-0001](adr/0001-arch-mirror-releases.md)。

## 用代理构建（makepkg）

PKGBUILD 的下载使用 curl，aarch64 的 Flutter 使用 git；两者都读取 `https_proxy`/`http_proxy`。本机访问 GitHub 受限时，可以给整个 `makepkg` 设置代理：

```sh
export https_proxy=http://127.0.0.1:7890
export http_proxy=$https_proxy
cd packaging/baocode   # 或 packaging/baocode-bin
makepkg -si
```

若只有 GitHub 被封锁，`https_proxy` 仍会作用于 GitHub 下载和 `git clone`；Flutter 存储与 rustup 的请求也会走代理，代理需能访问这些地址。

也可以先用 gh-proxy 手动把 `source=()` 中的文件下载到 makepkg 的源码缓存目录 `$SRCDEST`（未配置时就是 PKGBUILD 所在目录），makepkg 会校验哈希而不是重新下载：

```sh
cd packaging/baocode
commit=$(sed -n 's/^_commit=//p' PKGBUILD)
version=$(sed -n 's/^_upstream_version=//p' PKGBUILD)
curl -L -o "baocode-$commit.tar.gz" \
  "https://gh-proxy.com/https://github.com/NmouZh/baocode-for-archlinux/archive/$commit.tar.gz"
curl -L -o "BaoCode-$version-linux-amd64.tar.gz" \
  "https://gh-proxy.com/https://github.com/baocode-dev/baocode/releases/download/v$version/BaoCode-$version-linux-amd64.tar.gz"
makepkg -si
```

aarch64 把 `linux-amd64` 换成 `linux-arm64`。`prepare()` 里的 Flutter/Rust 下载不由 `source=()` 管理，仍需要 `https_proxy`（x86_64 的 Flutter 也可直连 Google 存储）。`baocode-bin` 与 AUR 的 PKGBUILD 只有一条上游 tarball，可以同样预下载后再构建。

## 维护者操作

### 触发与输入

workflow 文件是 `.github/workflows/arch-mirror.yml`（name `Arch mirror`），只有维护者可用：

- **自动**：`schedule.cron: '23 4 * * *'`，每日 04:23 UTC 运行一次。
- **手动**：`workflow_dispatch`，输入：
  - `version`：要镜像的上游 Release 版本，**不带 `v`**；留空取上游 latest Release。必须是 `X.Y.Z` 形式。
  - `force_rebuild`：布尔值，默认 `false`；为 `true` 时同一 `pkgver` 的 `pkgrel` 加一，把 `v<version>` tag 移到新的打包提交，并覆盖同名 Release 资产。

job 链是 `sync` → `prepare` → `build`（矩阵）→ `publish` → `aur`。`sync` 合并上游 `main` 并推送；冲突时打开或评论标题为 `[arch] 上游合并冲突` 的 issue（标签 `ready-for-human`）并让运行失败。默认只镜像上游最新 Release；显式 `version` 可创建旧版本 Release，但不会标为 latest，更新器也不依赖 latest。默认路径下源码包从合并提交构建，打包提交创建在 `main` 上；显式 `version` 从上游该 tag 的提交构建，打包提交创建在该提交上，`main` 不变。两种情况 Release tag 都指向打包提交。

流水线只用默认 `GITHUB_TOKEN`，不需要 PAT，也不需要自建签名密钥。

### 构建矩阵与仓库变量

`build` 的矩阵是 `pkg: [baocode, baocode-bin]` × `arch: [x86_64, aarch64]`：

- x86_64 在 `ubuntu-latest` 的 `archlinux:base-devel` 容器中构建。
- aarch64 在 `ubuntu-24.04-arm` 的 `menci/archlinuxarm:base-devel` 容器中构建。
- 每个包用 `pacman -Qip`、`namcap`、`bsdtar -tf` 校验后，以 `arch-<pkgname>-<arch>` 名称上传 artifact。

仓库变量 `ARCH_AARCH64_SOURCE` 控制 aarch64 源码包这条腿（设为 `ARCH_AARCH64_SOURCE=off` 可关闭）：

- 设为 `off`：跳过 `baocode`/`aarch64` 组合（该腿要在 ARM 上 clone Flutter 并编译应用）。
- 不设置或设为其他值：保留该腿。
- 该腿允许失败（`continue-on-error`），不阻塞 `publish`；失败时 Release 会少一个 aarch64 源码包。

### AUR 凭据与首次接入

以下是一次性人工步骤：

1. 在 aur.archlinux.org 网页创建包 `baocode-bin`。workflow 无法创建它；在包存在之前，推送步骤会失败。
2. 生成 SSH 密钥对，把公钥添加到 AUR 账号。
3. 把私钥内容保存为仓库 secret `AUR_SSH_PRIVATE_KEY`。

`aur` job 每次都先运行 `makepkg --printsrcinfo`，把结果与仓库中的 `packaging/aur/baocode-bin/.SRCINFO` 对比；不一致就失败，需用 `makepkg --printsrcinfo` 重新生成并提交。`AUR_SSH_PRIVATE_KEY` 为空时推送步骤跳过，发布仍成功；配置后它会 clone `ssh://aur@aur.archlinux.org/baocode-bin.git`，复制 `packaging/aur/baocode-bin/PKGBUILD` 与 `packaging/aur/baocode-bin/.SRCINFO`，提交 `upgpkg: baocode-bin $pkgver-$pkgrel`，并推送到 `master`。

### 手动发布回退

workflow 不可用或 AUR 推送失败时，仓库里的 AUR 文件就是手动发布的来源：

```sh
git clone ssh://aur@aur.archlinux.org/baocode-bin.git
cp packaging/aur/baocode-bin/PKGBUILD packaging/aur/baocode-bin/.SRCINFO baocode-bin/
cd baocode-bin
pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
pkgrel=$(sed -n 's/^pkgrel=//p' PKGBUILD)
git add PKGBUILD .SRCINFO
git commit -m "upgpkg: baocode-bin $pkgver-$pkgrel"
git push origin master
```

### 验证状态

**需在 Actions 启用后验证**：`sync` 的每日运行与冲突 issue、x86_64/aarch64 的 `makepkg`、四个包的构建与校验、`publish` 的 Release 创建/覆盖，以及 `aur` 的真实推送，都只能在 fork 的 GitHub Actions 中验证。fork 的 Actions 与定时 workflow 默认关闭，仓库所有者需先在 Actions 页面手动启用一次。本文档的本地验证只覆盖静态结构、命令/名称与链接。