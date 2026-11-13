# ADR-0002: Fork 保留自己的 workflow 文件

- 日期：2026-11-13
- 状态：Accepted
- 范围：Sync 合并上游 `main` 并推送时的 `.github/workflows/`
- 词汇：见 [GLOSSARY.md](../../GLOSSARY.md)
- 相关：[ADR-0001 镜像发布架构](0001-arch-mirror-releases.md)

## Status

Accepted（已接受）。本 ADR 细化 ADR-0001 第 1 节中 Sync 的推送行为，不改变其“只使用默认 `GITHUB_TOKEN`”的约束。

## Context

ADR-0001 要求核心流水线只使用默认 `GITHUB_TOKEN`，不引入 PAT 或额外的 GitHub App 凭据。

`GITHUB_TOKEN` 是 GitHub Actions 应用的安装令牌。GitHub App 创建或更新 `.github/workflows/` 下的文件需要 `workflows` 权限，而 workflow 的 `permissions:` 键没有该值，也无法授予它（它只接受 `contents`、`issues`、`pull-requests` 等仓库权限）。因此用 `GITHUB_TOKEN` 推送一个改动了 workflow 文件的提交会被服务端拒绝。

2026-11-13 的 [Arch mirror 运行 #43424639859](https://github.com/NmouZh/baocode-for-archlinux/actions/runs/43424639859) 正是这种情况：上游新增了 `.github/workflows/bash-exe.yml`，Sync 的 `git push origin main` 失败：

```
! [remote rejected] main -> main (refusing to allow a GitHub App to create or
update workflow `.github/workflows/bash-exe.yml` without `workflows` permission)
```

可行的替代方案都需要额外凭据：

- 带 `workflow` scope 的 PAT；
- 具有 `workflows` 权限的 GitHub App 安装令牌。

两者都与 ADR-0001 的 GITHUB_TOKEN-only 约束冲突。

## Decision

Sync 仍然合并上游 `main`，但合并提交不改动 `.github/workflows/`：合并后把该目录恢复到合并前 `origin/main` 的状态，并 amend 进合并提交。只有 `.github/workflows/` 内的冲突不算合并失败，按同一规则取本 fork 的版本；其他路径的冲突仍按 ADR-0001 开去重 issue 并让运行失败。

结果是上游对 workflow 文件的修改不会进入本 fork；本 fork 的 `arch-mirror.yml`、`release-retry.yml` 以及既有的上游 workflow 副本保持原样。上游 workflow 的更新对 Arch 打包没有作用：发布链由 `arch-mirror.yml` 自己承担。

## Consequences

**正面影响**

- Sync 继续只用 `GITHUB_TOKEN` 推送 `main`，无需 PAT 或额外 App。
- 上游新增 workflow 文件（如 `bash-exe.yml`）不再让每日同步失败。
- 只有真正需要人工处理的源码冲突才会开 issue。

**代价与限制**

- 合并提交在 `.github/workflows/` 上刻意与上游不同，上游该目录的更新不会被镜像。
- 若将来需要跟随上游 workflow 的改动，必须改用带 `workflows` 权限的凭据，并以新的 ADR 取代本决定。