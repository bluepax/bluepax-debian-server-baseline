# debian-server-baseline

一个脚本完成 Debian 服务器初始化：**幂等**（可反复执行）、**可验收**（逐项检查实际生效情况）、**持久**（软件升级和大版本升级后设置不丢失）、**感知云环境**（阻止 cloud-init 回滚设置）。

只面向 Debian 12 (bookworm) 及更新的稳定版，已在 Debian 12 / 13 上测试。

## 快速开始

```bash
git clone https://github.com/bluepax/bluepax-debian-server-baseline.git
cd bluepax-debian-server-baseline
sudo ./debian-baseline.sh
```

在终端中运行时，脚本默认是**交互式**的：

1. 主菜单：初始化或重新对齐、验收检查、安装到系统、版本信息。
2. 向导第一步：检测每个步骤当前是否已生效（✓ 已生效 / ✗ 未生效 / ! 需注意），由你选择要执行哪些步骤，默认全部执行，可以重复执行。
3. 向导第二步：根据所选步骤询问参数，包括管理用户名、主机名、Debian 镜像（官方、云厂商内网、阿里云、清华或自定义）、安全仓库、backports、deb-src、Docker 镜像，以及要额外粘贴的公钥。方括号里是默认值，直接回车即可采用。
4. 汇总确认后执行，执行中会提示为 `gb117` 设置密码，最后自动验收。

输入从 `/dev/tty` 读取，所以 `curl -fsSL <脚本地址> | sudo bash` 也能交互。

首次执行后，脚本会安装到 `/usr/local/sbin/debian-baseline`，选择的参数会记录到 `/etc/debian-baseline.conf`，作为下次运行时的默认值：

```bash
sudo debian-baseline           # 交互菜单
sudo debian-baseline check     # 只验收，不修改；有 FAIL 时退出码为 1
```

**非交互（自动化、cloud-init user-data、CI）**：加 `-y` 后不做任何询问，参数全部来自命令行或上次记录的配置：

```bash
sudo ./debian-baseline.sh apply -y -n web-01 -K ~/.ssh/id_ed25519.pub
```

## 做了什么

| # | 步骤 | 内容 | 持久化方式 |
|---|------|------|-----------|
| 1 | `apt` | 写入 `/etc/apt/sources.list.d/debian.sources`（deb822），包含当前大版本的 main / updates / security / backports 仓库，组件为 `main contrib non-free non-free-firmware`。清空 `sources.list`，停用其它重复的 Debian 源（会先备份） | 独立文件；cloud-init 设置 `apt: preserve_sources_list` |
| 2 | `packages` | 安装 `curl gnupg htop ufw vim wget`，以及后续步骤需要的 `ca-certificates sudo locales openssh-server` | — |
| 3 | `docker` | 添加 Docker 官方仓库 `docker.sources`，并校验 GPG 公钥指纹 `9DC8…CD88`。**只添加仓库，不安装 Docker** | 独立文件 |
| 4 | `user` | 创建用户组 `gb117`，以及主组为 `gb117`、属于 `sudo` 组的用户 `gb117`；导入 SSH 公钥；交互模式下提示设置密码 | — |
| 5 | `shell` | 全局别名（`ll`、`df -h` 等）、`force_color_prompt` 和彩色提示符（root 红色，普通用户绿色），对 root、bash、sh/dash 登录 shell、zsh 都生效 | 内容放在 `/etc/profile.d/zz-debian-baseline.sh`；`/etc/bash.bashrc`、`/etc/zsh/zshrc` 中只放一行带标记的引用 |
| 6 | `ssh` | 全局：允许公钥认证，禁止密码登录、keyboard-interactive、root 登录和 X11 转发。`127.0.0.1` / `::1`：允许密码登录和 root 登录 | `sshd_config.d/00-debian-baseline.conf`，按 sshd「先读到的值生效」规则压过 `50-cloud-init.conf`；cloud-init 设置 `ssh_pwauth: false` |
| 7 | `vim` | 显示行号 `number`，高亮搜索 `hlsearch`，鼠标只在插入模式启用 `mouse=i` | `/etc/vim/vimrc.local`。会先加载 `defaults.vim`，避免它把 `mouse` 改成 `a` |
| 8 | `locale` | 系统语言 `LANG=en_US.UTF-8`，时区 `Etc/UTC`；生成 `zh_CN.UTF-8` 但不启用 | `/etc/default/locale`、`/etc/locale.gen`；tzdata 的 debconf 也一并写入 |
| 9 | `hostname` | 设置 `/etc/hostname`、运行中的主机名和 `/etc/hosts` 中的 `127.0.1.1` 行 | cloud-init 设置 `preserve_hostname: true`、`manage_etc_hosts: false` |

所有改动都尽量写在**不属于软件包的文件**里（drop-in、`.local` 文件、独立文件），软件包升级不会覆盖它们。少数只能放进软件包配置文件的钩子（`/etc/bash.bashrc`、`/etc/zsh/zshrc`，以及 `sshd_config` 中的 `Include`）由 `/etc/apt/apt.conf.d/99debian-baseline` 处理：每次 dpkg 运行后自动执行 `debian-baseline heal` 重新挂载。所以即使升级时选择了「使用维护者版本」，钩子也会被自动补回。

## 默认用户与公钥

默认管理用户是 `gb117`。脚本内置一把它必须能登录的 ED25519 公钥（`DEFAULT_USER_KEYS`，指纹 `SHA256:3c0E3tZlQDWhi8IDlzwLDCH3jTaFC/3oDBfOwBIk2VI`）：每次 `apply` 都会确保这把公钥在 `~gb117/.ssh/authorized_keys` 中，`check` 也会核对它是否存在，以及文件权限是否满足 sshd `StrictModes` 的要求。用 `-u` 指定其他用户时不会添加这把公钥。

## 常用选项

```
-n, --hostname NAME        主机名（可为 FQDN）
-u, --user NAME            管理用户，默认 gb117
-k, --ssh-key "KEY"        添加公钥（可重复）
-K, --ssh-key-file FILE    从文件添加公钥（可重复）
    --import-keys-from U   从已有用户导入公钥，如 debian / root
    --mirror URL           Debian 主仓库，默认 http://deb.debian.org/debian
    --security-mirror URL  安全仓库，默认 http://security.debian.org/debian-security
    --docker-mirror URL    Docker 仓库，默认 https://download.docker.com/linux/debian
    --with-src / --no-backports
    --release CODENAME     用指定代号写 apt 源（大版本升级前使用）
    --only a,b / --skip a,b  只执行 / 跳过某些步骤：apt packages docker user shell ssh vim locale hostname
    --force                管理用户没有公钥时仍禁用 SSH 密码登录
-y, --yes                  非交互：不显示菜单和向导，不做任何询问
-V, --version              版本号、build 号、构建时间与提交号
```

## 云环境

- 脚本会检测 cloud-init、`cloud-id` 和 DMI 厂商信息。首次开机时如果 cloud-init 还在运行，会先等它完成，再写入 `/etc/cloud/cloud.cfg.d/99_zz_debian_baseline.cfg`，防止重启或从镜像克隆时设置被改回。
- **防止锁在门外**：如果没有指定公钥，而 `gb117` 也还没有公钥，脚本会自动从执行 `sudo` 的用户或 root 的 `authorized_keys` 导入。云厂商注入给 root 的 `command="..."` 前缀会被去掉。仍然没有公钥时，SSH 步骤会拒绝执行，除非加 `--force`。
- 默认使用 Debian 官方源。阿里云、腾讯云上会提示可用的内网镜像，例如：
  ```bash
  sudo ./debian-baseline.sh apply --mirror http://mirrors.cloud.aliyuncs.com/debian \
       --security-mirror http://mirrors.cloud.aliyuncs.com/debian-security \
       --docker-mirror https://mirrors.aliyun.com/docker-ce/linux/debian
  ```

## 大版本升级（例如 12 → 13）

```bash
sudo debian-baseline apply --release trixie --only apt,docker   # 先把源切到新版本
sudo apt full-upgrade && sudo reboot
sudo debian-baseline apply && sudo debian-baseline check        # 升级后重新对齐并验收
```

## 注意事项

- `ufw` 只安装、不启用。启用前先执行 `sudo ufw allow OpenSSH`。
- `gb117` 需要设置密码才能使用 `sudo`（`passwd gb117`）。root 要通过本机回环地址用密码登录，也需要先设置 root 密码。
- 每次修改文件前，原文件都会备份到 `/var/backups/debian-baseline/<时间戳>/`。新的 apt 源无法使用时会自动还原；sshd 配置校验失败时会还原 drop-in。
- `check` 检查的是实际生效的状态：`sshd -T -C` 模拟外部和回环地址的连接；以干净环境启动 bash/sh/zsh 读取别名和提示符；在没有 `~/.vimrc` 的条件下启动 vim 读取选项；`apt-cache policy` 确认索引来自正确的仓库。

## 版本与分支

本项目遵循 [Bluepax Flow](https://github.com/bluepax/bluepax-gitflow)：

- 版本号采用 SemVer 2.0。新主版本先发布 `X.0.0-beta.N`，N 是 build 号（`git rev-list --count --first-parent <dev 提交>`）；之后发布的 `X.0.0` 即正式版。次版本和修订版不设 beta。
- 每个主版本有一个代号，取自天空中的生物。1.x 的代号为 `petrel`（海燕）。
- `dev` 是默认分支，用于开发与热修复。`main` 只用于发布，每个提交都有附注标签 `vX.Y.Z`。功能在 `feature/*`、`fix/*` 分支上开发，通过 `--no-ff` 合并提交合入 `dev`。
- `debian-baseline --version` 显示版本号、代号、build 号、构建时间和提交号。这些信息的来源：从 git 工作区运行时实时读取；GitHub 源码包由 `export-subst` 填入；安装到 `/usr/local/sbin` 时写入安装副本。

## 许可证

[MIT](LICENSE)
