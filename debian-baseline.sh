#!/usr/bin/env bash
#
# debian-baseline — Debian 服务器初始化基线
#
#   * 幂等：可以反复执行，只修改与期望状态不一致的部分
#   * 可验收：`check` 子命令逐项检查实际生效情况
#   * 持久：只使用 drop-in / .local / 独立文件，软件升级与大版本升级后依旧生效
#   * 云环境感知：检测 cloud-init，阻止它在重启或重新实例化时回滚设置
#
# 用法: debian-baseline.sh <apply|check|heal|install> [选项]   (详见 --help)
#
# 必须用 bash ≥ 4 运行（用 sh/dash 或 macOS 自带的 bash 3.2 会报难懂的语法错误）
if [ -z "${BASH_VERSION:-}" ]; then
    echo "debian-baseline: 请用 bash 运行，例如: sudo bash $0" >&2
    exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "debian-baseline: 需要 bash 4 或更新版本（当前 $BASH_VERSION）" >&2
    exit 1
fi

# shellcheck disable=SC2317  # step_*/check_* are called indirectly
set -Eeuo pipefail
shopt -s nullglob

# ---------------------------------------------------------------- 版本信息 ---
# Bluepax Flow：SemVer 2.0，新主版本预发布为 X.0.0-beta.N，
# N 为 build 号 = git rev-list --count --first-parent <dev 提交>
SCRIPT_VERSION="1.0.0-beta.4"
SCRIPT_BUILD="4"
SCRIPT_CODENAME="petrel"
# 提交号与构建时间：git archive 时由 export-subst 填入（见 .gitattributes），
# install 时写入安装副本，从 git 工作区运行时实时读取
# shellcheck disable=SC2016
SCRIPT_COMMIT='$Format:%h$'
# shellcheck disable=SC2016
SCRIPT_DATE='$Format:%cI$'

readonly SELF_INSTALL_PATH="/usr/local/sbin/debian-baseline"
readonly CONF_FILE="/etc/debian-baseline.conf"
readonly BACKUP_ROOT="/var/backups/debian-baseline"
readonly MARK_BEGIN="# >>> debian-baseline (managed block, do not edit) >>>"
readonly MARK_END="# <<< debian-baseline <<<"
readonly MANAGED_HEADER="Managed by debian-baseline; local edits will be overwritten. Re-run: debian-baseline apply"

readonly DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
readonly DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_KEY="/etc/apt/keyrings/docker.asc"
readonly DOCKER_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
readonly APT_HOOK="/etc/apt/apt.conf.d/99debian-baseline"
readonly SHELL_SNIPPET="/etc/profile.d/zz-debian-baseline.sh"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-debian-baseline.conf"
readonly VIM_LOCAL="/etc/vim/vimrc.local"
readonly CLOUD_CFG="/etc/cloud/cloud.cfg.d/99_zz_debian_baseline.cfg"

readonly BASE_PACKAGES=(curl gnupg htop ufw vim wget)
readonly SUPPORT_PACKAGES=(ca-certificates sudo locales openssh-server)
readonly ALL_STEPS=(apt packages docker user shell ssh vim locale hostname)
readonly LOCALES_WANTED=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
readonly SYSTEM_LANG="en_US.UTF-8"
readonly SYSTEM_TZ="Etc/UTC"
readonly APT_LOG="/var/log/debian-baseline-apt.log"
readonly SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 公钥：类型 + base64；用于从 authorized_keys 中提取（会去掉 command=... 等前缀选项）
readonly KEY_RE='(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/]{20,}={0,3}([[:space:]].*)?$'
# Debian 发行代号，用于识别残留的 Debian 官方/镜像源条目
readonly DEBIAN_SUITES_RE='(buster|bullseye|bookworm|trixie|forky|duke|oldoldstable|oldstable|stable|testing|unstable|sid)(-security|-updates|-backports|-proposed-updates)?'

# 默认管理用户及其必须能登录的公钥（使用 -u 指定其他用户时不会添加）
readonly DEFAULT_USER="gb117"
readonly DEFAULT_USER_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvVdx3I6reyG9ZxZ/gSgFATCGtzdAu1AwwPURCJo+Qj gb117"
)

# ---------------------------------------------------------------- 可配置项 ---
# 默认值 < /etc/debian-baseline.conf（上次 apply 记录）< 命令行参数
BL_USER="$DEFAULT_USER"
BL_HOSTNAME=""
APT_MIRROR="http://deb.debian.org/debian"
APT_SECURITY_MIRROR="http://security.debian.org/debian-security"
DOCKER_MIRROR="https://download.docker.com/linux/debian"
APT_WITH_SRC="no"
APT_BACKPORTS="yes"

OPT_USER="" OPT_HOSTNAME="" OPT_MIRROR="" OPT_SECURITY_MIRROR="" OPT_DOCKER_MIRROR=""
OPT_WITH_SRC="" OPT_BACKPORTS="" OPT_RELEASE="" OPT_ONLY="" OPT_SKIP=""
FORCE="no" ASSUME_YES="no"
SSH_KEYS=() SSH_KEY_FILES=() IMPORT_KEYS_FROM=()

# 运行期状态
CODENAME="" OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_PRETTY=""
HAS_SYSTEMD="no" IN_CONTAINER="no" VIRT="none" CLOUD_INIT="absent" CLOUD_PLATFORM="" DMI_VENDOR="" IS_CLOUD="no"
BACKUP_DIR="" FILE_CHANGED=0 APT_UPDATED="no" INTERACTIVE="no"
STEPS=()

# ------------------------------------------------------------------ 输出 ---
if [ -t 1 ]; then
    C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_0=$'\e[0m'
else
    C_R="" C_G="" C_Y="" C_B="" C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%sWARN:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
trap 'printf "%sERROR:%s 第 %s 行命令失败: %s\n" "$C_R" "$C_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
    cat <<EOF
debian-baseline ${SCRIPT_VERSION} — Debian 服务器初始化基线（幂等，可重复执行）

用法:
  debian-baseline.sh                  交互式菜单（在终端中运行时）
  debian-baseline.sh apply   [选项]   应用设置，结束后自动验收；在终端中会先进入交互式向导，-y 跳过
  debian-baseline.sh check   [选项]   只做验收，不修改系统；有 FAIL 时退出码为 1
  debian-baseline.sh install          把脚本安装到 ${SELF_INSTALL_PATH} 并注册 apt 自愈钩子
  debian-baseline.sh heal             重新挂载被软件包升级覆盖的钩子（由 apt 钩子自动调用）

步骤（按执行顺序）: ${ALL_STEPS[*]}

选项:
  -n, --hostname NAME        主机名（可为 FQDN）。首次未提供时交互询问
  -u, --user NAME            管理用户，默认 gb117
  -k, --ssh-key "KEY"        为管理用户添加公钥（可重复）
  -K, --ssh-key-file FILE    从文件添加公钥（可重复）
      --import-keys-from U   从已有用户的 authorized_keys 导入公钥（可重复，如 debian / root）
      --mirror URL           Debian 主仓库地址，默认 ${APT_MIRROR}
      --security-mirror URL  安全更新仓库地址，默认 ${APT_SECURITY_MIRROR}
      --docker-mirror URL    Docker 仓库地址，默认 ${DOCKER_MIRROR}
      --with-src             同时启用 deb-src
      --no-backports         不启用 backports
      --release CODENAME     使用指定发行代号写 apt 源（大版本升级前切换源用）
      --only a,b,c           只执行这些步骤
      --skip a,b,c           跳过这些步骤
      --force                管理用户没有任何公钥时也禁用 SSH 密码登录（可能把自己锁在门外）
  -y, --yes                  非交互模式，不做任何询问
  -V, --version              显示版本号、build 号、构建时间与提交号
  -h, --help                 显示帮助

参数会记录到 ${CONF_FILE}，之后直接执行 \`debian-baseline apply\` / \`check\` 即可复用。
EOF
}

# 解析提交号与构建时间：export-subst/install 已填入则直接使用，否则从 git 工作区读取
resolve_build_info() {
    local dir src
    if [[ $SCRIPT_COMMIT == '$Format'* ]] || [[ $SCRIPT_DATE == '$Format'* ]]; then
        # 只读取脚本自身所在的 git 工作区；通过管道运行时没有脚本文件，不能去读当前目录
        src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
        dir=$(dirname "${src:-/nonexistent/x}")
        if [ -f "$src" ] && command -v git >/dev/null 2>&1 &&
           git -c safe.directory='*' -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            SCRIPT_COMMIT=$(git -c safe.directory='*' -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)
            SCRIPT_DATE=$(git -c safe.directory='*' -C "$dir" log -1 --format=%cI 2>/dev/null || echo unknown)
            if [ "$SCRIPT_COMMIT" != unknown ] && [ -n "$(git -c safe.directory='*' -C "$dir" status --porcelain -- "$(basename "${BASH_SOURCE[0]}")" 2>/dev/null)" ]; then
                SCRIPT_COMMIT="${SCRIPT_COMMIT}-dirty"
            fi
        else
            SCRIPT_COMMIT="unknown" SCRIPT_DATE="unknown"
        fi
    fi
}

version_line() { echo "debian-baseline ${SCRIPT_VERSION} (${SCRIPT_CODENAME}, build ${SCRIPT_BUILD}, commit ${SCRIPT_COMMIT}, ${SCRIPT_DATE})"; }

print_version() {
    cat <<EOF
debian-baseline
  version:  ${SCRIPT_VERSION}
  codename: ${SCRIPT_CODENAME}
  build:    ${SCRIPT_BUILD}
  date:     ${SCRIPT_DATE}
  commit:   ${SCRIPT_COMMIT}
EOF
}

# ---------------------------------------------------------------- 参数解析 ---
parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
        case $1 in
            -n|--hostname)        _need "$@"; OPT_HOSTNAME=$2; shift 2 ;;
            -u|--user)            _need "$@"; OPT_USER=$2; shift 2 ;;
            -k|--ssh-key)         _need "$@"; SSH_KEYS+=("$2"); shift 2 ;;
            -K|--ssh-key-file)    _need "$@"; SSH_KEY_FILES+=("$2"); shift 2 ;;
            --import-keys-from)   _need "$@"; IMPORT_KEYS_FROM+=("$2"); shift 2 ;;
            --mirror)             _need "$@"; OPT_MIRROR=$2; shift 2 ;;
            --security-mirror)    _need "$@"; OPT_SECURITY_MIRROR=$2; shift 2 ;;
            --docker-mirror)      _need "$@"; OPT_DOCKER_MIRROR=$2; shift 2 ;;
            --with-src)           OPT_WITH_SRC="yes"; shift ;;
            --no-src)             OPT_WITH_SRC="no"; shift ;;
            --backports)          OPT_BACKPORTS="yes"; shift ;;
            --no-backports)       OPT_BACKPORTS="no"; shift ;;
            --release)            _need "$@"; OPT_RELEASE=$2; shift 2 ;;
            --only)               _need "$@"; OPT_ONLY=$2; shift 2 ;;
            --skip)               _need "$@"; OPT_SKIP=$2; shift 2 ;;
            --force)              FORCE="yes"; shift ;;
            -y|--yes)             ASSUME_YES="yes"; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    die "未知参数: $1（--help 查看用法）" ;;
        esac
    done
}
_need() { [ $# -ge 2 ] && [ -n "$2" ] || die "参数 $1 需要一个值"; }

load_conf() {
    [ -f "$CONF_FILE" ] || return 0
    # 只信任 root 拥有且他人不可写的配置文件
    if [ -z "$(find "$CONF_FILE" -maxdepth 0 -user root ! -perm /022 2>/dev/null)" ]; then
        warn "$CONF_FILE 不属于 root 或可被他人写入，已忽略"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$CONF_FILE"
}

apply_overrides() {
    [ -n "$OPT_USER" ]            && BL_USER=$OPT_USER
    [ -n "$OPT_HOSTNAME" ]        && BL_HOSTNAME=$OPT_HOSTNAME
    [ -n "$OPT_MIRROR" ]          && APT_MIRROR=$OPT_MIRROR
    [ -n "$OPT_SECURITY_MIRROR" ] && APT_SECURITY_MIRROR=$OPT_SECURITY_MIRROR
    [ -n "$OPT_DOCKER_MIRROR" ]   && DOCKER_MIRROR=$OPT_DOCKER_MIRROR
    [ -n "$OPT_WITH_SRC" ]        && APT_WITH_SRC=$OPT_WITH_SRC
    [ -n "$OPT_BACKPORTS" ]       && APT_BACKPORTS=$OPT_BACKPORTS
    BL_HOSTNAME=${BL_HOSTNAME,,}   # 主机名不区分大小写，统一小写，避免验收比较失败
    APT_MIRROR=${APT_MIRROR%/} APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR%/} DOCKER_MIRROR=${DOCKER_MIRROR%/}

    [[ $BL_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "用户名不合法: $BL_USER"
    if [ -n "$BL_HOSTNAME" ]; then
        valid_hostname "$BL_HOSTNAME" || die "主机名不合法: $BL_HOSTNAME（字母/数字/连字符，每段 ≤63，总长 ≤253）"
    fi
    if [ "$ASSUME_YES" = "no" ] && has_tty; then INTERACTIVE="yes"; fi
}

valid_hostname() {
    local h=$1 label
    [[ $h =~ ^[A-Za-z0-9.-]+$ ]] && [ ${#h} -le 253 ] || return 1
    local IFS=.
    for label in $h; do
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    [[ $h != .* && $h != *. && $h != *..* ]]
}

select_steps() {
    local s
    _valid_steps "$OPT_ONLY"; _valid_steps "$OPT_SKIP"
    STEPS=()
    for s in "${ALL_STEPS[@]}"; do
        if [ -n "$OPT_ONLY" ] && ! _in_list "$s" "$OPT_ONLY"; then continue; fi
        if [ -n "$OPT_SKIP" ] && _in_list "$s" "$OPT_SKIP"; then continue; fi
        STEPS+=("$s")
    done
    [ ${#STEPS[@]} -gt 0 ] || die "没有选中任何步骤"
}
_in_list() { [[ ",$2," == *",$1,"* ]]; }
_valid_steps() {
    local s IFS=,
    for s in $1; do
        _in_list "$s" "$(IFS=,; echo "${ALL_STEPS[*]}")" || die "未知步骤: $s（可选: ${ALL_STEPS[*]}）"
    done
}
step_selected() { local s; for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ---------------------------------------------------------------- 环境检测 ---
require_root() { [ "$(id -u)" -eq 0 ] || die "请以 root 运行（sudo $0 ...）"; }

load_os() {
    [ -r /etc/os-release ] || die "找不到 /etc/os-release"
    eval "$(
        # shellcheck disable=SC1091
        . /etc/os-release
        printf 'OS_ID=%q OS_VERSION_ID=%q OS_CODENAME=%q OS_PRETTY=%q\n' \
            "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-}"
    )"
    [ "$OS_ID" = "debian" ] || die "只支持 Debian（当前: ${OS_PRETTY:-$OS_ID}）"
    [[ $OS_VERSION_ID =~ ^[0-9]+$ ]] || die "只支持 Debian 稳定版（testing/sid 没有 VERSION_ID）"
    [ "$OS_VERSION_ID" -ge 12 ] || die "需要 Debian 12 (bookworm) 或更新版本，当前 ${OS_PRETTY}"
    CODENAME=${OPT_RELEASE:-$OS_CODENAME}
    [[ $CODENAME =~ ^[a-z]+$ ]] || die "无法确定发行代号: '$CODENAME'"
}

detect_env() {
    [ -d /run/systemd/system ] && HAS_SYSTEMD="yes"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt 2>/dev/null || true); VIRT=${VIRT:-none}
        systemd-detect-virt -cq 2>/dev/null && IN_CONTAINER="yes"
    fi
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && IN_CONTAINER="yes"
    DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)

    if command -v cloud-init >/dev/null 2>&1 && [ -d /etc/cloud ]; then
        if [ -e /etc/cloud/cloud-init.disabled ] || grep -qw 'cloud-init=disabled' /proc/cmdline 2>/dev/null; then
            CLOUD_INIT="disabled"
        else
            CLOUD_INIT="enabled"
            CLOUD_PLATFORM=$(cloud-id 2>/dev/null || true)
        fi
    fi
    if [ "$CLOUD_INIT" = "enabled" ] && [ -n "$CLOUD_PLATFORM" ] && [ "$CLOUD_PLATFORM" != "none" ]; then
        IS_CLOUD="yes"
    elif [[ $DMI_VENDOR =~ (Alibaba|Tencent|Amazon|Google|Microsoft|DigitalOcean|Hetzner|Vultr|Linode|Akamai|Huawei|OpenStack|Oracle|Scaleway|OVH|UpCloud) ]]; then
        IS_CLOUD="yes"
    fi
}

print_env() {
    log "$(version_line)"
    log "环境: ${OS_PRETTY}（apt 代号: ${CODENAME}）"
    info "systemd: ${HAS_SYSTEMD}  虚拟化: ${VIRT}  容器: ${IN_CONTAINER}"
    info "云环境: ${IS_CLOUD}  cloud-init: ${CLOUD_INIT}${CLOUD_PLATFORM:+ (${CLOUD_PLATFORM})}${DMI_VENDOR:+  厂商: ${DMI_VENDOR}}"
    [ "$CODENAME" = "$OS_CODENAME" ] || warn "apt 源将使用 ${CODENAME}，而系统当前是 ${OS_CODENAME}（--release）"
    [ "$IN_CONTAINER" = "yes" ] && warn "运行在容器中：主机名、时区、sshd 可能由宿主机/编排器管理"
    return 0
}

wait_cloud_init() {
    [ "$CLOUD_INIT" = "enabled" ] || return 0
    local st
    st=$(cloud-init status 2>/dev/null || true)
    if [[ $st == *running* ]]; then
        log "cloud-init 仍在运行（首次开机），等待其完成，避免之后覆盖本脚本的设置 ..."
        timeout 900 cloud-init status --wait >/dev/null 2>&1 || warn "等待 cloud-init 超时，继续执行"
    fi
}

mirror_hint() {
    [ "$APT_MIRROR" = "http://deb.debian.org/debian" ] || return 0
    case $DMI_VENDOR in
        *Alibaba*) info "提示: 阿里云 ECS 可用内网镜像 --mirror http://mirrors.cloud.aliyuncs.com/debian --security-mirror http://mirrors.cloud.aliyuncs.com/debian-security" ;;
        *Tencent*) info "提示: 腾讯云可用内网镜像 --mirror http://mirrors.tencentyun.com/debian --security-mirror http://mirrors.tencentyun.com/debian-security" ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 文件工具 ---
backup_file() {
    local f=$1
    [ -e "$f" ] || return 0
    # 每次运行一个独立目录（含进程号，同一秒内多次运行也不会混用备份）
    [ -n "$BACKUP_DIR" ] || BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    [ -e "$BACKUP_DIR$f" ] || cp -a "$f" "$BACKUP_DIR$f"
}

# 把文件移入备份目录（用于停用冲突的 apt 源文件）
disable_file() {
    backup_file "$1"
    rm -f "$1"
    info "已停用 $1（备份: $BACKUP_DIR$1）"
}

# install_content DEST MODE  —— 内容来自 stdin；内容相同则不动。设置 FILE_CHANGED
install_content() {
    local dest=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; FILE_CHANGED=0; return 0
    fi
    backup_file "$dest"
    mkdir -p "$(dirname "$dest")"
    # 原子替换；失败时（如容器里被 bind-mount 的 /etc/hosts、/etc/hostname）改为原地写入
    if ! install -m "$mode" -o root -g root "$tmp" "$dest" 2>/dev/null; then
        cat "$tmp" >"$dest"
        chmod "$mode" "$dest"
    fi
    rm -f "$tmp"
    FILE_CHANGED=1
    info "已更新 $dest"
}

# ensure_block FILE CONTENT —— 在文件末尾维护一段带标记的内容（已存在则原地替换后移到末尾）
ensure_block() {
    local file=$1 content=$2 mode=0644
    [ -f "$file" ] && mode=$(stat -c %a "$file")
    # 用进程替换而不是管道：install_content 必须在当前 shell 运行，FILE_CHANGED/BACKUP_DIR 才能传回
    install_content "$file" "$mode" < <(
        if [ -f "$file" ]; then
            awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
                $0 == b { skip = 1; next }
                skip    { if ($0 == e) skip = 0; next }
                /^[[:space:]]*$/ { blank = blank $0 "\n"; next }
                { printf "%s", blank; blank = ""; print }
            ' "$file"
        fi
        printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "$content" "$MARK_END"
    )
}

has_block() { [ -f "$1" ] && grep -qxF "$MARK_BEGIN" "$1"; }

# ---------------------------------------------------------------- apt 工具 ---
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -q \
        -o DPkg::Lock::Timeout=600 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# apt-get update 的错误行（下载失败、GPG 错误、源文件格式错误等）
readonly APT_ERR_RE='^(E:|Err:|W: (Failed to fetch|GPG error|The repository))'
APT_UPDATE_OUT=""

# 运行 apt-get update；任一软件源失败时返回 1，输出保存在 APT_UPDATE_OUT
apt_update() {
    local rc=0
    info "apt-get update ..."
    APT_UPDATE_OUT=$(apt_get update 2>&1) || rc=$?
    APT_UPDATED="yes"
    if [ $rc -ne 0 ] || grep -qE "$APT_ERR_RE" <<<"$APT_UPDATE_OUT"; then
        return 1
    fi
    { grep -E '^W:' <<<"$APT_UPDATE_OUT" || true; } | while IFS= read -r l; do warn "$l"; done
    return 0
}

# 上次 apt-get update 中与给定 URL/文件有关的错误行
apt_errors_for() {
    local needle
    for needle in "$@"; do
        grep -E "$APT_ERR_RE" <<<"$APT_UPDATE_OUT" | grep -F -- "$needle" || true
    done | sort -u
}

# 与本脚本无关的软件源失败：只提示，不影响本步骤
WARNED_REPOS=" "
warn_other_apt_errors() {
    local repo
    # 每个失败的源只提示一次（同一次运行里多次 apt update 也不重复）
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        [[ $WARNED_REPOS == *" $repo "* ]] && continue
        WARNED_REPOS="$WARNED_REPOS$repo "
        warn "其它软件源更新失败（与本脚本无关，已忽略）: $repo"
    done < <(grep -E "$APT_ERR_RE" <<<"$APT_UPDATE_OUT" | grep -oE "(https?|ftp|file|mirror\+[a-z]+)://[^ ']+" | sort -u || true)
}

pkg_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]; }

ensure_pkgs() {
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    [ ${#missing[@]} -eq 0 ] && return 0
    if [ "$APT_UPDATED" != "yes" ] && ! apt_update; then
        warn_other_apt_errors
        warn "部分软件源更新失败，继续尝试安装"
    fi
    info "安装: ${missing[*]}（日志: $APT_LOG）"
    if ! apt_get install -y "${missing[@]}" >>"$APT_LOG" 2>&1; then
        tail -n 20 "$APT_LOG" >&2
        die "软件包安装失败，详见 $APT_LOG"
    fi
}

debian_keyring() {
    local f
    for f in /usr/share/keyrings/debian-archive-keyring.pgp /usr/share/keyrings/debian-archive-keyring.gpg; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    echo ""
}

# 识别 Debian 官方/镜像仓库的条目（逐条判断，第三方条目不受影响）：
#   URI 以 /debian 或 /debian-security 结尾、套件是 Debian 代号、
#   组件全部是 main/contrib/non-free/non-free-firmware、
#   signed-by 为空或是 debian-archive-keyring
# 例如 nginx.org/packages/debian bookworm nginx、repo.mysql.com/apt/debian bookworm mysql-8.0
# 的组件不是 Debian 组件，因此不会被误判。
# 变量: fmt=list|deb822  mode=classify（输出「启用条目数 Debian条目数」）|disable（输出停用后的内容）
readonly APT_ENTRY_AWK='
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
function okuri(u) { sub(/\/+$/, "", u); return u ~ /\/debian(-security)?$/ && u !~ /download\.docker\.com|\/docker-ce\// }
function isdeb(uris, suites, comps, sb,   a, n, i, hit) {
    n = split(uris, a); if (n == 0) return 0
    for (i = 1; i <= n; i++) if (!okuri(a[i])) return 0
    n = split(suites, a); hit = 0
    for (i = 1; i <= n; i++) if (a[i] ~ ("^" suite_re "$")) hit = 1
    if (!hit) return 0
    n = split(comps, a); if (n == 0) return 0
    for (i = 1; i <= n; i++) if (a[i] !~ /^(main|contrib|non-free|non-free-firmware)$/) return 0
    return sb == "" || sb ~ /debian-archive-keyring/
}
function list_entry(line,   t, n, i, j, opts, comps, sb) {
    if (line ~ /^[ \t]*(#|$)/) return -1
    sub(/[ \t]#.*/, "", line)
    n = split(line, t)
    if (t[1] != "deb" && t[1] != "deb-src") return -1
    i = 2; opts = ""
    if (t[2] ~ /^\[/) { while (i <= n) { opts = opts " " t[i]; if (t[i++] ~ /\]$/) break } }
    comps = ""; for (j = i + 2; j <= n; j++) comps = comps " " t[j]
    sb = ""; if (match(opts, /signed-by=[^ \]]+/)) sb = substr(opts, RSTART, RLENGTH)
    return isdeb(t[i], t[i + 1], comps, sb)
}
function flush(   d, i, en) {
    if (n == 0) return
    en = tolower(f["enabled"]) != "no"
    d = en && isdeb(f["uris"], f["suites"], f["components"], f["signed-by"])
    if (en) { total++; if (d) deb++ }
    if (mode == "disable") {
        for (i = 1; i <= n; i++) if (!(d && tolower(lines[i]) ~ /^enabled:/)) print lines[i]
        if (d) print "Enabled: no"
    }
    n = 0; key = ""; split("", f)
}
fmt == "list" {
    r = list_entry($0)
    if (r >= 0) { total++; if (r) deb++ }
    if (mode == "disable") print (r == 1 ? "# [disabled by debian-baseline] " : "") $0
    next
}
/^[ \t]*$/ { flush(); if (mode == "disable") print; next }
{
    lines[++n] = $0
    if ($0 ~ /^#/) next
    if ($0 ~ /^[ \t]/) { if (key != "") f[key] = f[key] " " trim($0); next }
    p = index($0, ":"); if (p == 0) next
    key = tolower(trim(substr($0, 1, p - 1))); f[key] = trim(substr($0, p + 1))
}
END { if (fmt != "list") flush(); if (mode == "classify") print total + 0, deb + 0 }
'

_apt_awk() {  # MODE FILE
    local fmt=list
    [[ $2 == *.sources ]] && fmt=deb822
    awk -v mode="$1" -v fmt="$fmt" -v suite_re="$DEBIAN_SUITES_RE" "$APT_ENTRY_AWK" "$2"
}

# 文件中启用的 Debian 仓库条目数
debian_entry_count() {
    local total=0 deb=0
    [ -f "$1" ] && read -r total deb < <(_apt_awk classify "$1")
    echo "${deb:-0}"
}

# 停用文件中的 Debian 仓库条目：整个文件都是 Debian 条目则移走（先备份），否则只停用这些条目
disable_debian_entries() {
    local f=$1 total=0 deb=0
    read -r total deb < <(_apt_awk classify "$f")
    [ "${deb:-0}" -gt 0 ] || return 0
    if [ "$f" != /etc/apt/sources.list ] && [ "$deb" -eq "$total" ]; then
        disable_file "$f"
    else
        install_content "$f" "$(stat -c %a "$f")" < <(_apt_awk disable "$f")
        info "已停用 $f 中的 $deb 条 Debian 源（其它 $((total - deb)) 条保留）"
    fi
}

# 输出含有其它 Debian 仓库条目的源文件（本脚本管理的文件除外）
conflicting_debian_sources() {
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ "$f" = "$DEBIAN_SOURCES" ] || [ "$f" = "$DOCKER_SOURCES" ] && continue
        [ "$(debian_entry_count "$f")" -gt 0 ] && echo "$f"
    done
    return 0
}

other_docker_sources() {
    local f
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ "$f" = "$DOCKER_SOURCES" ] && continue
        grep -Eqi '^[^#]*(download\.docker\.com|/docker-ce/)' "$f" && echo "$f"
    done
    return 0
}


# ---------------------------------------------------------------- cloud-init ---
ensure_cloud_cfg() {
    [ -d /etc/cloud ] || return 0
    install_content "$CLOUD_CFG" 0644 < <(
        echo "#cloud-config"
        echo "# $MANAGED_HEADER"
        echo "# Keep cloud-init from reverting settings applied by debian-baseline"
        echo "# on reboot or when this machine is re-instantiated from an image."
        echo "ssh_pwauth: false"
        echo "apt:"
        echo "  preserve_sources_list: true"
        if [ -n "$BL_HOSTNAME" ]; then
            echo "preserve_hostname: true"
            echo "manage_etc_hosts: false"
        fi
    )
}

# ================================================================== 步骤 ===

step_apt() {
    local keyring types suites comps signed
    # https 镜像需要 CA 证书：先用原有的源装好，再切换
    if [[ $APT_MIRROR == https://* || $APT_SECURITY_MIRROR == https://* ]] && ! pkg_installed ca-certificates; then
        info "https 镜像需要 ca-certificates，先用现有软件源安装"
        ensure_pkgs ca-certificates
    fi
    keyring=$(debian_keyring)
    [ -n "$keyring" ] || ensure_pkgs debian-archive-keyring
    keyring=$(debian_keyring)
    signed=${keyring:+Signed-By: $keyring}
    types="deb"; [ "$APT_WITH_SRC" = "yes" ] && types="deb deb-src"
    suites="$CODENAME $CODENAME-updates"; [ "$APT_BACKPORTS" = "yes" ] && suites="$suites $CODENAME-backports"
    comps="main contrib non-free non-free-firmware"

    install_content "$DEBIAN_SOURCES" 0644 <<EOF
# $MANAGED_HEADER
# Debian ${CODENAME} — official repositories (deb822 format, see sources.list(5))

Types: $types
URIs: $APT_MIRROR
Suites: $suites
Components: $comps
${signed}

Types: $types
URIs: $APT_SECURITY_MIRROR
Suites: $CODENAME-security
Components: $comps
${signed}
EOF

    # 停用其它位置的 Debian 源（含 sources.list），第三方条目保留
    local f errs
    while IFS= read -r f; do
        [ -n "$f" ] && disable_debian_entries "$f"
    done < <(conflicting_debian_sources)

    ensure_cloud_cfg

    apt_update || true
    errs=$(apt_errors_for "$APT_MIRROR" "$APT_SECURITY_MIRROR" "$DEBIAN_SOURCES")
    if [ -z "$errs" ]; then
        warn_other_apt_errors
    else
        printf '%s\n' "$errs" >&2
        warn "新的 Debian 源不可用，正在还原 apt 源 ..."
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/etc/apt" ]; then
            [ -e "$BACKUP_DIR$DEBIAN_SOURCES" ] || rm -f "$DEBIAN_SOURCES"
            cp -a "$BACKUP_DIR/etc/apt/." /etc/apt/
        else
            rm -f "$DEBIAN_SOURCES"
        fi
        die "新 apt 源不可用（网络或镜像地址问题？可用 --mirror 指定镜像），已还原"
    fi
}

step_packages() {
    ensure_pkgs "${BASE_PACKAGES[@]}" "${SUPPORT_PACKAGES[@]}"
    info "已安装: ${BASE_PACKAGES[*]} ${SUPPORT_PACKAGES[*]}"
    info "注意: ufw 只安装不启用；启用前请先 'ufw allow OpenSSH'"
}

step_docker() {
    ensure_pkgs ca-certificates curl gnupg
    local arch tmpd fpr f
    arch=$(dpkg --print-architecture)

    if ! curl -fsSL --retry 3 --connect-timeout 15 -o /dev/null "$DOCKER_MIRROR/dists/$CODENAME/Release"; then
        warn "Docker 仓库 ${DOCKER_MIRROR} 不可达或尚不支持 ${CODENAME}，跳过（可用 --docker-mirror 指定镜像）"
        return 0
    fi

    tmpd=$(mktemp -d)
    curl -fsSL --retry 3 --connect-timeout 15 -o "$tmpd/docker.asc" "$DOCKER_MIRROR/gpg"
    fpr=$(gpg --homedir "$tmpd" --batch --show-keys --with-colons "$tmpd/docker.asc" 2>/dev/null | awk -F: '$1=="fpr"{print $10}')
    if ! grep -qx "$DOCKER_FPR" <<<"$fpr"; then
        rm -rf "$tmpd"
        die "Docker GPG 公钥指纹不匹配（期望 $DOCKER_FPR），已中止"
    fi
    install -d -m 0755 /etc/apt/keyrings
    install_content "$DOCKER_KEY" 0644 <"$tmpd/docker.asc"
    rm -rf "$tmpd"

    while IFS= read -r f; do
        [ -n "$f" ] && disable_file "$f"
    done < <(other_docker_sources)

    install_content "$DOCKER_SOURCES" 0644 <<EOF
# $MANAGED_HEADER
# Docker CE official repository — packages are NOT installed by debian-baseline.
# Install with: apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

Types: deb
URIs: $DOCKER_MIRROR
Suites: $CODENAME
Components: stable
Architectures: $arch
Signed-By: $DOCKER_KEY
EOF
    local errs
    apt_update || true
    errs=$(apt_errors_for "$DOCKER_MIRROR" "$DOCKER_SOURCES")
    if [ -n "$errs" ]; then
        printf '%s\n' "$errs" >&2
        # 撤掉不可用的 Docker 源，避免之后每次 apt update 都报错
        if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR$DOCKER_SOURCES" ]; then cp -a "$BACKUP_DIR$DOCKER_SOURCES" "$DOCKER_SOURCES"
        else rm -f "$DOCKER_SOURCES"; fi
        die "Docker 仓库不可用（可用 --docker-mirror 指定镜像），已撤销 $DOCKER_SOURCES"
    fi
    warn_other_apt_errors
}

# 从 stdin 提取规范化的公钥行
extract_keys() { grep -v '^[[:space:]]*#' | grep -oE "$KEY_RE" || true; }

count_keys() {
    [ -f "$1" ] || { echo 0; return 0; }
    extract_keys <"$1" | grep -c . || true
}

user_home() { getent passwd "$1" | cut -d: -f6; }

default_keys_for() {
    [ "$1" = "$DEFAULT_USER" ] || return 0
    printf '%s\n' "${DEFAULT_USER_KEYS[@]}"
}

gather_keys() {
    local k f u h
    { default_keys_for "$BL_USER"; for k in "${SSH_KEYS[@]}"; do printf '%s\n' "$k"; done; } | extract_keys
    for f in "${SSH_KEY_FILES[@]}"; do
        [ -r "$f" ] || die "无法读取公钥文件 $f"
        extract_keys <"$f"
    done
    for u in "${IMPORT_KEYS_FROM[@]}"; do
        h=$(user_home "$u") || true
        [ -n "$h" ] || die "--import-keys-from: 用户 $u 不存在"
        if [ -r "$h/.ssh/authorized_keys" ]; then extract_keys <"$h/.ssh/authorized_keys"
        else warn "$u 没有 authorized_keys"; fi
    done
}

install_keys() {
    local u=$1 home akf added=0 line blob src h
    home=$(user_home "$u")
    akf="$home/.ssh/authorized_keys"
    local -a keys=()
    mapfile -t keys < <(gather_keys)

    # 未指定公钥且用户还没有公钥：自动从执行 sudo 的用户 / root 导入（云主机通常已注入）
    if [ ${#keys[@]} -eq 0 ] && [ "$(count_keys "$akf")" -eq 0 ]; then
        for src in "${SUDO_USER:-}" root; do
            [ -n "$src" ] && [ "$src" != "$u" ] || continue
            h=$(user_home "$src") || true
            [ -n "$h" ] && [ -r "$h/.ssh/authorized_keys" ] || continue
            mapfile -t keys < <(extract_keys <"$h/.ssh/authorized_keys")
            if [ ${#keys[@]} -gt 0 ]; then
                info "自动从 $src 的 authorized_keys 导入 ${#keys[@]} 把公钥"
                break
            fi
        done
    fi

    install -d -m 0700 -o "$u" -g "$u" "$home/.ssh"
    [ -f "$akf" ] || install -m 0600 -o "$u" -g "$u" /dev/null "$akf"
    for line in "${keys[@]}"; do
        blob=$(awk '{print $2}' <<<"$line")
        if ! grep -qF -- "$blob" "$akf"; then
            printf '%s\n' "$line" >>"$akf"
            added=$((added + 1))
        fi
    done
    chown "$u:$u" "$akf"; chmod 0600 "$akf"
    [ $added -gt 0 ] && info "已为 $u 添加 $added 把公钥"
    info "$u 当前共有 $(count_keys "$akf") 把公钥"
    return 0
}

step_user() {
    local u=$BL_USER pg st
    getent group "$u" >/dev/null || { groupadd "$u"; info "已创建用户组 $u"; }
    if id "$u" >/dev/null 2>&1; then
        pg=$(id -gn "$u")
        if [ "$pg" != "$u" ]; then usermod -g "$u" "$u"; info "已把 $u 的主组从 $pg 改为 $u"; fi
    else
        useradd -m -s /bin/bash -g "$u" "$u"
        info "已创建用户 $u（主组 $u，shell /bin/bash）"
    fi
    if ! id -nG "$u" | tr ' ' '\n' | grep -qx sudo; then
        usermod -aG sudo "$u"; info "已把 $u 加入 sudo 组"
    fi

    install_keys "$u"

    st=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
    if [ "$st" != "P" ]; then
        if [ "$INTERACTIVE" = "yes" ]; then
            info "为 $u 设置密码（sudo 与本机回环 SSH 登录使用）:"
            local i
            for i in 1 2 3; do passwd "$u" </dev/tty && break; [ "$i" = 3 ] && warn "密码未设置"; done
        else
            warn "$u 尚未设置密码，sudo 无法使用；请执行: passwd $u"
        fi
    fi
}

shell_hook() { printf 'if [ -r %s ]; then . %s; fi' "$SHELL_SNIPPET" "$SHELL_SNIPPET"; }

write_shell_snippet() {
    install_content "$SHELL_SNIPPET" 0644 <<'EOF'
# shellcheck shell=sh
# Managed by debian-baseline; local edits will be overwritten. Re-run: debian-baseline apply
#
# Global interactive-shell settings for every user, including root.
# Loaded from: /etc/bash.bashrc  (every interactive bash, login or not)
#              /etc/profile      (login sh/dash/bash, via /etc/profile.d)
#              /etc/zsh/zshrc    (zsh, if installed)

case $- in
    *i*) ;;
    *) return 0 ;;
esac
[ -n "${__debian_baseline_shell:-}" ] && return 0
__debian_baseline_shell=1

# for a colored prompt, if the terminal has the capability
# (also honoured by the per-user ~/.bashrc copied from /etc/skel)
force_color_prompt=yes

# root's ~/.bashrc has no prompt logic, so set a colored prompt here:
# red for root, green for everyone else.
if [ -n "${BASH_VERSION:-}" ] && [ -x /usr/bin/tput ] && tput setaf 1 >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then __bl_c='01;31'; else __bl_c='01;32'; fi
    PS1='${debian_chroot:+($debian_chroot)}\[\033['"$__bl_c"'m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    unset __bl_c
fi

# global alias
alias ls='ls --color=auto'
alias ll='ls -lhFa'
alias l='ls -lhF'
alias dir='dir --color=auto'
alias vdir='vdir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias df='df -h'
alias du='du -ch'
alias free='free -h'
EOF
}

install_shell_hooks() {
    ensure_block /etc/bash.bashrc "$(shell_hook)"
    if [ -f /etc/zsh/zshrc ]; then ensure_block /etc/zsh/zshrc "$(shell_hook)"; fi
    return 0
}

step_shell() {
    write_shell_snippet
    install_shell_hooks
}

sshd_bin() { command -v sshd 2>/dev/null || echo /usr/sbin/sshd; }

ensure_sshd_include() {
    local cfg=/etc/ssh/sshd_config
    FILE_CHANGED=0
    [ -f "$cfg" ] || return 0
    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$cfg"; then
        install_content "$cfg" 0644 < <(echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "$cfg")
    fi
}

reload_sshd() {
    if [ "$HAS_SYSTEMD" = "yes" ]; then
        local unit
        for unit in ssh.service sshd.service; do
            if systemctl is-active --quiet "$unit"; then
                systemctl reload "$unit" && info "已重新加载 $unit（现有连接不会断开）"
                return 0
            fi
        done
        if systemctl is-active --quiet ssh.socket; then
            info "sshd 由 ssh.socket 按需启动，新连接会直接使用新配置"
            return 0
        fi
    fi
    warn "sshd 未在运行（或无 systemd），配置将在其下次启动时生效"
}

step_ssh() {
    ensure_pkgs openssh-server
    local nkeys=0 home
    if id "$BL_USER" >/dev/null 2>&1; then
        home=$(user_home "$BL_USER")
        nkeys=$(count_keys "$home/.ssh/authorized_keys")
    fi
    if [ "$nkeys" -eq 0 ] && [ "$FORCE" != "yes" ]; then
        if [ "$INTERACTIVE" = "yes" ] && ask_yn "$BL_USER 没有任何 SSH 公钥，禁用密码登录可能把你锁在门外。仍然继续?" n; then
            FORCE="yes"
        fi
    fi
    if [ "$nkeys" -eq 0 ] && [ "$FORCE" != "yes" ]; then
        die "$BL_USER 没有任何 SSH 公钥，禁用密码登录会把你锁在门外。请用 -k/-K/--import-keys-from 提供公钥，或加 --force"
    fi

    ensure_sshd_include
    local inc_changed=$FILE_CHANGED
    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    install_content "$SSHD_DROPIN" 0644 <<EOF
# $MANAGED_HEADER
#
# sshd uses the FIRST value it reads for each keyword. This file sorts as 00-*,
# so it is read before distro/cloud drop-ins such as 50-cloud-init.conf and
# before the rest of /etc/ssh/sshd_config, and therefore wins.

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
X11Forwarding no

# Loopback only: allow password and root login (local console, SSH tunnels).
Match Address 127.0.0.1,::1
    PasswordAuthentication yes
    PermitRootLogin yes
EOF
    local changed=$FILE_CHANGED err
    [ "$inc_changed" = 1 ] && changed=1
    if ! err=$("$(sshd_bin)" -t 2>&1); then
        warn "sshd 配置校验失败: $err"
        if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR$SSHD_DROPIN" ]; then cp -a "$BACKUP_DIR$SSHD_DROPIN" "$SSHD_DROPIN"
        else rm -f "$SSHD_DROPIN"; fi
        if [ "$inc_changed" = 1 ] && [ -e "$BACKUP_DIR/etc/ssh/sshd_config" ]; then
            cp -a "$BACKUP_DIR/etc/ssh/sshd_config" /etc/ssh/sshd_config
        fi
        die "已还原 sshd 配置，未做任何改变"
    fi
    ensure_cloud_cfg
    [ "$changed" = 1 ] && reload_sshd
    return 0
}

step_vim() {
    ensure_pkgs vim
    install_content "$VIM_LOCAL" 0644 <<EOF
" $MANAGED_HEADER
"
" Vim loads \$VIMRUNTIME/defaults.vim AFTER the system vimrc when a user has
" no ~/.vimrc, which would override the settings below (e.g. mouse=a).
" Load it here first, then stop vim from loading it a second time.
if filereadable(expand('\$VIMRUNTIME/defaults.vim'))
  source \$VIMRUNTIME/defaults.vim
endif
let g:skip_defaults_vim = 1

set number      " show line numbers
set hlsearch    " highlight search matches
set mouse=i     " mouse support in insert mode only
EOF
    grep -q 'vimrc.local' /etc/vim/vimrc 2>/dev/null ||
        warn "/etc/vim/vimrc 未引用 vimrc.local（被改动过？），设置可能不生效"
    return 0
}

step_locale() {
    ensure_pkgs locales tzdata
    local loc re tmp
    tmp=$(mktemp)
    if [ -f /etc/locale.gen ]; then cp /etc/locale.gen "$tmp"; fi
    for loc in "${LOCALES_WANTED[@]}"; do
        re=${loc//./\\.}
        sed -i -E "s/^[[:space:]]*#[[:space:]]*(${re})[[:space:]]*$/\1/" "$tmp"
        grep -qxF "$loc" "$tmp" || printf '%s\n' "$loc" >>"$tmp"
    done
    install_content /etc/locale.gen 0644 <"$tmp"
    rm -f "$tmp"

    local have
    have=$(locale -a 2>/dev/null || true)
    if [ "$FILE_CHANGED" = 1 ] || ! grep -qix 'en_US.utf8' <<<"$have" || ! grep -qix 'zh_CN.utf8' <<<"$have"; then
        info "生成 locale: en_US.UTF-8 zh_CN.UTF-8 ..."
        locale-gen >/dev/null
    fi

    # 系统语言只设 LANG，清除 LC_*/LANGUAGE 覆盖；中文 locale 已生成但不启用
    if [ "$(grep -Ev '^[[:space:]]*(#|$)' /etc/default/locale 2>/dev/null | tr -d '"')" != "LANG=$SYSTEM_LANG" ]; then
        backup_file /etc/default/locale
        update-locale --reset "LANG=$SYSTEM_LANG"
        info "已设置系统语言 LANG=$SYSTEM_LANG（重新登录后生效）"
    fi

    # 时区：同时写 debconf，tzdata 升级时不会改回
    debconf-set-selections <<EOF
tzdata tzdata/Areas select Etc
tzdata tzdata/Zones/Etc select UTC
EOF
    if [ "$(readlink -f /etc/localtime 2>/dev/null)" != "$(readlink -f /usr/share/zoneinfo/$SYSTEM_TZ)" ]; then
        if [ "$HAS_SYSTEMD" = "yes" ] && timedatectl set-timezone "$SYSTEM_TZ" 2>/dev/null; then :
        else ln -sfn "/usr/share/zoneinfo/$SYSTEM_TZ" /etc/localtime; fi
        info "已设置时区 $SYSTEM_TZ"
    fi
    if [ -f /etc/timezone ]; then install_content /etc/timezone 0644 <<<"$SYSTEM_TZ"; fi
    return 0
}

step_hostname() {
    if [ -z "$BL_HOSTNAME" ]; then
        warn "未指定主机名（-n NAME），跳过"
        return 0
    fi
    local h=$BL_HOSTNAME short line
    short=${h%%.*}
    install_content /etc/hostname 0644 <<<"$h"
    if [ "$HAS_SYSTEMD" = "yes" ] && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$h" 2>/dev/null || hostname "$h" 2>/dev/null || warn "无法设置运行中的主机名"
    else
        hostname "$h" 2>/dev/null || warn "无法设置运行中的主机名（容器？）"
    fi

    line=$(printf '127.0.1.1\t%s' "$h"); [ "$short" != "$h" ] && line="$line $short"
    install_content /etc/hosts 0644 < <(awk -v l="$line" '
        /^[[:space:]]*127\.0\.1\.1[[:space:]]/ { if (!done) print l; done = 1; next }
        { print }
        END { if (!done) print l }
    ' /etc/hosts)
    ensure_cloud_cfg
}

# ---------------------------------------------------------- 自安装与自愈 ---
install_self() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    if [ -f "$src" ]; then
        if [ "$src" != "$SELF_INSTALL_PATH" ]; then
            install -m 0755 -o root -g root "$src" "$SELF_INSTALL_PATH"
            # 把提交号与构建时间写入安装副本，脱离 git 工作区后仍可查看
            sed -i -e "s|^SCRIPT_COMMIT=.*|SCRIPT_COMMIT='${SCRIPT_COMMIT}'|" \
                   -e "s|^SCRIPT_DATE=.*|SCRIPT_DATE='${SCRIPT_DATE}'|" "$SELF_INSTALL_PATH"
            info "已安装 $(version_line) 到 $SELF_INSTALL_PATH，之后可直接执行: debian-baseline check"
        fi
    else
        warn "脚本不是从文件运行（管道？），跳过自安装"
    fi
    install_content "$APT_HOOK" 0644 <<EOF
// $MANAGED_HEADER
// After every dpkg run, re-attach the hooks debian-baseline keeps in
// package-owned files (/etc/bash.bashrc, /etc/zsh/zshrc, sshd Include),
// in case an upgrade replaced them with the maintainer's version.
DPkg::Post-Invoke { "if [ -x $SELF_INSTALL_PATH ]; then $SELF_INSTALL_PATH heal >/dev/null 2>&1 || true; fi"; };
EOF
}

do_heal() {
    [ -d /run/systemd/system ] && HAS_SYSTEMD="yes"
    if [ -f "$SHELL_SNIPPET" ]; then install_shell_hooks; fi
    if [ -f "$SSHD_DROPIN" ]; then
        ensure_sshd_include
        if [ "$FILE_CHANGED" = 1 ] && "$(sshd_bin)" -t >/dev/null 2>&1; then reload_sshd; fi
    fi
    return 0
}

save_conf() {
    install_content "$CONF_FILE" 0644 < <(
        echo "# $MANAGED_HEADER"
        echo "# Parameters of the last 'apply'; reused by later runs. Command-line options win."
        printf 'BL_USER=%q\n' "$BL_USER"
        printf 'BL_HOSTNAME=%q\n' "$BL_HOSTNAME"
        printf 'APT_MIRROR=%q\n' "$APT_MIRROR"
        printf 'APT_SECURITY_MIRROR=%q\n' "$APT_SECURITY_MIRROR"
        printf 'DOCKER_MIRROR=%q\n' "$DOCKER_MIRROR"
        printf 'APT_WITH_SRC=%q\n' "$APT_WITH_SRC"
        printf 'APT_BACKPORTS=%q\n' "$APT_BACKPORTS"
    )
}

# ================================================================== 验收 ===
CHK_PASS=0 CHK_FAIL=0 CHK_WARN=0 CHK_STEP=""
_chk()  { printf '  %s%s%s %-9s %s\n' "$1" "$2" "$C_0" "$CHK_STEP" "$3"; }
pass()  { CHK_PASS=$((CHK_PASS + 1)); _chk "$C_G" "[PASS]" "$*"; }
fail()  { CHK_FAIL=$((CHK_FAIL + 1)); _chk "$C_R" "[FAIL]" "$*"; }
cwarn() { CHK_WARN=$((CHK_WARN + 1)); _chk "$C_Y" "[WARN]" "$*"; }
expect() { if [ "$2" = "$3" ]; then pass "$1 = $2"; else fail "$1 = ${2:-<空>}（期望 $3）"; fi; }
kv() { awk -v k="$1" '$1 == k { print $2; exit }' <<<"$2"; }

# 以指定用户、干净环境运行交互式 shell 命令，返回其输出
run_as() {
    local u=$1 sh=$2 flags=$3 cmd=$4 home
    home=$(user_home "$u")
    if [ "$u" = root ]; then
        env -i HOME="$home" TERM=xterm PATH="$SAFE_PATH" "$sh" "$flags" "$cmd" </dev/null 2>/dev/null || true
    else
        runuser -u "$u" -- env -i HOME="$home" TERM=xterm PATH="$SAFE_PATH" "$sh" "$flags" "$cmd" </dev/null 2>/dev/null || true
    fi
}

check_apt() {
    if [ -f "$DEBIAN_SOURCES" ] && grep -qF "$MANAGED_HEADER" "$DEBIAN_SOURCES"; then
        pass "$DEBIAN_SOURCES 由本脚本管理（deb822）"
    else
        fail "$DEBIAN_SOURCES 不存在或不是本脚本生成的"
    fi
    if grep -Eq "^Suites:[[:space:]]+${CODENAME}([[:space:]]|$)" "$DEBIAN_SOURCES" 2>/dev/null &&
       grep -Eq "^Suites:[[:space:]]+${CODENAME}-security([[:space:]]|$)" "$DEBIAN_SOURCES" 2>/dev/null; then
        pass "源代号与系统一致: ${CODENAME} / ${CODENAME}-security"
    else
        fail "源中的代号不是 ${CODENAME}（大版本升级后请重新 apply）"
    fi
    local others
    others=$(conflicting_debian_sources | tr '\n' ' ')
    if [ -n "$others" ]; then fail "其它文件中仍有启用的 Debian 源: $others"
    else pass "sources.list 及 sources.list.d 中没有重复的 Debian 源"; fi

    local pol
    pol=$(apt-cache policy 2>/dev/null || true)
    if grep -qF " $APT_MIRROR $CODENAME/main " <<<"$pol"; then pass "已加载索引: $APT_MIRROR $CODENAME"
    else fail "未加载 $APT_MIRROR $CODENAME 的索引（apt-get update 未成功？）"; fi
    if grep -qF " $APT_SECURITY_MIRROR $CODENAME-security/main " <<<"$pol"; then pass "已加载索引: $APT_SECURITY_MIRROR $CODENAME-security"
    else fail "未加载 $CODENAME-security 的索引"; fi
    _check_cloud_key "preserve_sources_list: true" "cloud-init 不会覆盖 apt 源"
}

_check_cloud_key() {
    [ "$CLOUD_INIT" = "absent" ] && return 0
    if grep -qF "$1" "$CLOUD_CFG" 2>/dev/null; then pass "$2（$CLOUD_CFG）"
    else fail "$2: $CLOUD_CFG 缺少 '$1'"; fi
}

check_packages() {
    local p missing=()
    for p in "${BASE_PACKAGES[@]}" "${SUPPORT_PACKAGES[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then pass "已安装: ${BASE_PACKAGES[*]} ${SUPPORT_PACKAGES[*]}"
    else fail "未安装: ${missing[*]}"; fi
    if command -v ufw >/dev/null 2>&1; then
        local st; st=$(ufw status 2>/dev/null | head -n1 || true)
        info "    ufw: ${st:-未知}（本脚本不启用防火墙）"
    fi
}

check_docker() {
    local fpr pol cand
    if [ -f "$DOCKER_KEY" ]; then
        local gh; gh=$(mktemp -d)
        fpr=$(gpg --homedir "$gh" --batch --show-keys --with-colons "$DOCKER_KEY" 2>/dev/null | awk -F: '$1=="fpr"{print $10}' || true)
        rm -rf "$gh"
        if grep -qx "$DOCKER_FPR" <<<"$fpr"; then pass "Docker 公钥指纹正确 ($DOCKER_KEY)"
        else fail "Docker 公钥指纹不匹配 ($DOCKER_KEY)"; fi
    else
        fail "缺少 $DOCKER_KEY"
    fi
    if grep -Eq "^Suites:[[:space:]]+${CODENAME}$" "$DOCKER_SOURCES" 2>/dev/null; then pass "$DOCKER_SOURCES → $CODENAME"
    else fail "$DOCKER_SOURCES 不存在或代号不是 $CODENAME"; fi
    local others; others=$(other_docker_sources | tr '\n' ' ')
    [ -z "$others" ] || fail "存在重复的 Docker 源文件: $others"
    pol=$(apt-cache policy docker-ce 2>/dev/null || true)
    cand=$(awk '/Candidate:/ { print $2 }' <<<"$pol")
    if [ -n "$cand" ] && [ "$cand" != "(none)" ] && grep -qF "$DOCKER_MIRROR $CODENAME/stable" <<<"$pol"; then
        pass "可安装 docker-ce $cand（来自 $DOCKER_MIRROR）"
    else
        fail "apt 找不到 docker-ce 候选版本"
    fi
}

check_user() {
    local u=$BL_USER home st n
    if ! id "$u" >/dev/null 2>&1; then fail "用户 $u 不存在"; return 0; fi
    pass "用户 $u 存在 (uid $(id -u "$u"))"
    expect "$u 主组" "$(id -gn "$u")" "$u"
    if id -nG "$u" | tr ' ' '\n' | grep -qx sudo; then pass "$u 属于 sudo 组"; else fail "$u 不在 sudo 组"; fi
    home=$(user_home "$u")
    n=$(count_keys "$home/.ssh/authorized_keys")
    if [ "$n" -gt 0 ]; then pass "$u 有 $n 把 SSH 公钥"; else fail "$u 没有 SSH 公钥（密码登录已禁用，将无法远程登录）"; fi
    local line blob
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        blob=$(awk '{print $2}' <<<"$line")
        if [ -f "$home/.ssh/authorized_keys" ] && grep -qF -- "$blob" "$home/.ssh/authorized_keys"; then
            pass "$u 包含默认公钥 $(awk '{print $3}' <<<"$line")"
        else
            fail "$u 缺少默认公钥 $(awk '{print $3}' <<<"$line")"
        fi
    done < <(default_keys_for "$u")
    if [ -d "$home/.ssh" ] && [ "$(stat -c '%U %a' "$home/.ssh")" = "$u 700" ] &&
       [ "$(stat -c '%U %a' "$home/.ssh/authorized_keys" 2>/dev/null)" = "$u 600" ]; then
        pass "$home/.ssh 权限正确 (700/600, 属主 $u)"
    else
        fail "$home/.ssh 或 authorized_keys 的属主/权限不对（sshd StrictModes 会拒绝公钥）"
    fi
    st=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
    if [ "$st" = "P" ]; then pass "$u 已设置密码（sudo 可用）"; else cwarn "$u 未设置密码，sudo 不可用: passwd $u"; fi
}

check_shell() {
    local out
    [ -f "$SHELL_SNIPPET" ] && pass "$SHELL_SNIPPET 存在" || fail "缺少 $SHELL_SNIPPET"
    if has_block /etc/bash.bashrc; then pass "/etc/bash.bashrc 已挂载钩子"; else fail "/etc/bash.bashrc 缺少钩子（执行 debian-baseline heal）"; fi
    if [ -f /etc/zsh/zshrc ]; then
        if has_block /etc/zsh/zshrc; then pass "/etc/zsh/zshrc 已挂载钩子"; else fail "/etc/zsh/zshrc 缺少钩子"; fi
    fi

    out=$(run_as root bash -ic 'alias ll; printf "%s\n" "$PS1"')
    if grep -qF "ls -lhFa" <<<"$out"; then pass "root bash: alias ll 生效"; else fail "root bash: alias ll 未生效"; fi
    if grep -qF '01;31m' <<<"$out"; then pass "root bash: 彩色提示符生效"; else fail "root bash: 彩色提示符未生效"; fi
    out=$(run_as root sh -lic 'alias ll')
    if grep -qF "ls -lhFa" <<<"$out"; then pass "root sh 登录 shell: alias ll 生效"; else fail "root sh 登录 shell: alias ll 未生效"; fi
    if id "$BL_USER" >/dev/null 2>&1; then
        out=$(run_as "$BL_USER" bash -ic 'alias ll; alias df; printf "%s\n" "$PS1"')
        if grep -qF "ls -lhFa" <<<"$out" && grep -qF "df -h" <<<"$out"; then pass "$BL_USER bash: 别名生效"
        else fail "$BL_USER bash: 别名未生效（~/.bashrc 覆盖了？）"; fi
        if grep -qF '01;32m' <<<"$out"; then pass "$BL_USER bash: 彩色提示符生效"; else cwarn "$BL_USER bash: 提示符不是彩色（~/.bashrc 自定义了 PS1？）"; fi
    fi
    if command -v zsh >/dev/null 2>&1; then
        out=$(run_as root zsh -ic 'alias ll')
        if grep -qF "ls -lhFa" <<<"$out"; then pass "root zsh: alias ll 生效"; else fail "root zsh: alias ll 未生效"; fi
    fi
}

check_ssh() {
    local sshd pub l4 l6 err
    sshd=$(sshd_bin)
    if [ ! -x "$sshd" ]; then fail "未安装 openssh-server"; return 0; fi
    [ -f "$SSHD_DROPIN" ] && pass "$SSHD_DROPIN 存在" || fail "缺少 $SSHD_DROPIN"
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        pass "sshd_config 包含 sshd_config.d/*.conf"
    else
        fail "sshd_config 未 Include sshd_config.d（drop-in 不会生效）"
    fi
    mkdir -p /run/sshd
    if ! err=$("$sshd" -t 2>&1); then fail "sshd -t 校验失败: $err"; return 0; fi

    # 用 sshd -T -C 模拟不同来源的连接，得到「最终生效」的配置
    pub=$("$sshd" -T -C "user=$BL_USER,host=client.example,addr=203.0.113.10,laddr=198.51.100.1,lport=22" 2>/dev/null || true)
    l4=$("$sshd" -T -C "user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null || true)
    l6=$("$sshd" -T -C "user=root,host=localhost,addr=::1,laddr=::1,lport=22" 2>/dev/null || true)
    expect "外部 pubkeyauthentication"          "$(kv pubkeyauthentication "$pub")" yes
    expect "外部 passwordauthentication"        "$(kv passwordauthentication "$pub")" no
    expect "外部 kbdinteractiveauthentication"  "$(kv kbdinteractiveauthentication "$pub")" no
    expect "外部 permitrootlogin"               "$(kv permitrootlogin "$pub")" no
    expect "外部 x11forwarding"                 "$(kv x11forwarding "$pub")" no
    expect "127.0.0.1 passwordauthentication"   "$(kv passwordauthentication "$l4")" yes
    expect "127.0.0.1 permitrootlogin"          "$(kv permitrootlogin "$l4")" yes
    expect "::1 passwordauthentication"         "$(kv passwordauthentication "$l6")" yes
    expect "::1 permitrootlogin"                "$(kv permitrootlogin "$l6")" yes

    if [ "$HAS_SYSTEMD" = "yes" ]; then
        if systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service ||
           systemctl is-active --quiet ssh.socket; then
            pass "ssh 服务运行中"
        else
            cwarn "ssh 服务未运行"
        fi
    fi
    _check_cloud_key "ssh_pwauth: false" "cloud-init 不会重新开启密码登录"
}

check_vim() {
    if ! command -v vim >/dev/null 2>&1; then fail "未安装 vim"; return 0; fi
    [ -f "$VIM_LOCAL" ] && pass "$VIM_LOCAL 存在" || fail "缺少 $VIM_LOCAL"
    # 以「没有 ~/.vimrc 的新用户」身份启动 vim，读取最终生效的选项
    local tmp out
    tmp=$(mktemp -d)
    env -i HOME="$tmp" TERM=xterm PATH="$SAFE_PATH" vim -N -i NONE -n --not-a-term \
        -c "redir! > $tmp/out" -c 'silent set number? hlsearch? mouse?' -c 'redir END' -c 'qa!' \
        </dev/null >/dev/null 2>&1 || true
    out=$(tr -s ' \n' '  ' <"$tmp/out" 2>/dev/null || true)
    rm -rf "$tmp"
    if [ -z "$out" ]; then fail "无法读取 vim 实际选项"; return 0; fi
    if [[ " $out " == *" number "* ]]; then pass "vim: number（显示行号）"; else fail "vim: 未开启 number（$out）"; fi
    if [[ " $out " == *" hlsearch "* ]]; then pass "vim: hlsearch（高亮搜索）"; else fail "vim: 未开启 hlsearch（$out）"; fi
    if [[ " $out " == *" mouse=i "* ]]; then pass "vim: mouse=i（仅插入模式鼠标）"; else fail "vim: mouse 不是 i（$out）"; fi
}

check_locale() {
    local lang have tz
    lang=$(grep -E '^[[:space:]]*LANG=' /etc/default/locale 2>/dev/null | tail -n1 | tr -d '" ' || true)
    expect "/etc/default/locale" "$lang" "LANG=$SYSTEM_LANG"
    if grep -Eq '^[[:space:]]*(LC_[A-Z]+|LANGUAGE)=' /etc/default/locale 2>/dev/null; then
        cwarn "/etc/default/locale 里还有 LC_*/LANGUAGE 覆盖"
    fi
    have=$(locale -a 2>/dev/null || true)
    if grep -qix 'en_US.utf8' <<<"$have"; then pass "locale en_US.UTF-8 已生成"; else fail "locale en_US.UTF-8 未生成"; fi
    if grep -qix 'zh_CN.utf8' <<<"$have"; then pass "locale zh_CN.UTF-8 已生成（未启用）"; else fail "locale zh_CN.UTF-8 未生成"; fi

    tz=$(readlink -f /etc/localtime 2>/dev/null || true)
    if [[ $tz == */zoneinfo/UTC || $tz == */zoneinfo/Etc/UTC ]]; then pass "/etc/localtime → $tz"; else fail "/etc/localtime → ${tz:-<无>}（期望 UTC）"; fi
    expect "当前时区缩写 (date +%Z)" "$(env -u TZ date +%Z)" "UTC"
    if [ "$HAS_SYSTEMD" = "yes" ] && command -v timedatectl >/dev/null 2>&1; then
        local t; t=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        if [ "$t" = "UTC" ] || [ "$t" = "Etc/UTC" ]; then pass "timedatectl Timezone = $t"; else fail "timedatectl Timezone = ${t:-<空>}"; fi
    fi
}

check_hostname() {
    local h=$BL_HOSTNAME short
    if [ -z "$h" ]; then cwarn "未配置期望主机名（apply -n NAME），当前为 $(hostname)"; return 0; fi
    short=${h%%.*}
    expect "/etc/hostname" "$(head -n1 /etc/hostname 2>/dev/null)" "$h"
    if [ "$(hostname)" = "$h" ]; then pass "运行中主机名 = $h"
    elif [ "$IN_CONTAINER" = "yes" ]; then cwarn "运行中主机名 = $(hostname)（容器内由宿主机决定，/etc/hostname 已设置）"
    else fail "运行中主机名 = $(hostname)（期望 $h）"; fi
    if awk -v h="$h" '$1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' /etc/hosts; then
        pass "/etc/hosts: 127.0.1.1 → $h"
    else
        fail "/etc/hosts 中没有 127.0.1.1 $h"
    fi
    if getent hosts "$short" >/dev/null 2>&1; then pass "主机名可解析 ($short)"; else cwarn "主机名 $short 无法解析"; fi
    _check_cloud_key "preserve_hostname: true" "cloud-init 不会改回主机名"
}

check_persist() {
    CHK_STEP="persist"
    if [ -x "$SELF_INSTALL_PATH" ]; then pass "已安装 $SELF_INSTALL_PATH"; else cwarn "未安装到 $SELF_INSTALL_PATH（执行 install）"; fi
    if [ -f "$APT_HOOK" ]; then pass "apt 自愈钩子 $APT_HOOK"; else cwarn "缺少 apt 自愈钩子 $APT_HOOK"; fi
}

run_checks() {
    CHK_PASS=0 CHK_FAIL=0 CHK_WARN=0
    log "验收"
    local s
    for s in "${STEPS[@]}"; do
        CHK_STEP=$s
        "check_$s"
    done
    check_persist
    echo
    printf '验收结果: %s%d PASS%s, %s%d FAIL%s, %s%d WARN%s\n' \
        "$C_G" "$CHK_PASS" "$C_0" "$C_R" "$CHK_FAIL" "$C_0" "$C_Y" "$CHK_WARN" "$C_0"
    [ "$CHK_FAIL" -eq 0 ]
}

# ================================================================ 交互界面 ===
# 从 /dev/tty 读取输入：即使通过 `curl ... | sudo bash` 运行也能交互
# 只要能打开控制终端就算交互（输出经过 `| tee log` 时依然可以交互）
has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask VAR "提示" "默认值"
ask() {
    local __var=$1 __prompt=$2 __def=${3:-} __ans=""
    [ -n "$__def" ] && __prompt="$__prompt [${__def}]"
    IFS= read -r -p "  ${__prompt}: " __ans </dev/tty || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_yn "提示" [y|n]  —— 回答「是」返回 0
ask_yn() {
    local def=${2:-y} ans="" hint="[Y/n]"
    [ "$def" = "n" ] && hint="[y/N]"
    while :; do
        IFS= read -r -p "  $1 $hint: " ans </dev/tty || true
        ans=${ans:-$def}
        case ${ans,,} in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
        echo "  请输入 y 或 n"
    done
}

# choose VAR "标题" 默认序号 "选项1" "选项2" ...  —— VAR 得到选中的序号
choose() {
    local __var=$1 __title=$2 __def=$3 __ans="" __i
    shift 3
    echo "  $__title"
    for ((__i = 1; __i <= $#; __i++)); do printf '    %d) %s\n' "$__i" "${!__i}"; done
    while :; do
        IFS= read -r -p "  请选择 [${__def}]: " __ans </dev/tty || true
        __ans=${__ans:-$__def}
        if [[ $__ans =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le $# ]; then
            printf -v "$__var" '%s' "$__ans"
            return 0
        fi
        echo "  无效选择"
    done
}

step_title() {
    case $1 in
        apt)      echo "切换为当前大版本的官方 Debian 软件源（deb822 .sources）" ;;
        packages) echo "安装基础软件包: ${BASE_PACKAGES[*]}" ;;
        docker)   echo "添加 Docker 官方仓库（只加仓库，不安装）" ;;
        user)     echo "创建管理用户与同名用户组，加入 sudo，配置公钥" ;;
        shell)    echo "全局 shell 别名与彩色提示符（含 root）" ;;
        ssh)      echo "SSH 仅公钥登录、禁 root；回环地址允许密码与 root" ;;
        vim)      echo "Vim 行号、高亮搜索、仅插入模式鼠标" ;;
        locale)   echo "LANG=en_US.UTF-8、时区 UTC、生成中文 locale" ;;
        hostname) echo "设置主机名" ;;
    esac
}

# 静默跑一遍验收，得到每个步骤当前是否已生效
declare -A STEP_STATE=()
probe_status() {
    local s f w
    for s in "${ALL_STEPS[@]}"; do
        f=$CHK_FAIL w=$CHK_WARN CHK_STEP=$s
        "check_$s" >/dev/null 2>&1 || true
        if [ "$CHK_FAIL" -gt "$f" ]; then STEP_STATE[$s]="todo"
        elif [ "$CHK_WARN" -gt "$w" ]; then STEP_STATE[$s]="warn"
        else STEP_STATE[$s]="ok"; fi
    done
    CHK_PASS=0 CHK_FAIL=0 CHK_WARN=0
}

print_step_table() {
    local i=0 s mark
    for s in "${ALL_STEPS[@]}"; do
        i=$((i + 1))
        case ${STEP_STATE[$s]:-todo} in
            ok)   mark="${C_G}✓ 已生效${C_0}" ;;
            warn) mark="${C_Y}! 需注意${C_0}" ;;
            *)    mark="${C_R}✗ 未生效${C_0}" ;;
        esac
        printf '    %d) %-9s %s  %s\n' "$i" "$s" "$mark" "$(step_title "$s")"
    done
}

# 把「1 3 5」「1,3」「apt ssh」「a」解析为步骤列表
parse_step_selection() {
    local input=${1//,/ } tok out=()
    if [ -z "$input" ] || [ "$input" = "a" ] || [ "$input" = "all" ]; then
        STEPS=("${ALL_STEPS[@]}"); return 0
    fi
    for tok in $input; do
        if [[ $tok =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le ${#ALL_STEPS[@]} ]; then
            out+=("${ALL_STEPS[$((tok - 1))]}")
        elif _in_list "$tok" "$(IFS=,; echo "${ALL_STEPS[*]}")"; then
            out+=("$tok")
        else
            return 1
        fi
    done
    # 按标准执行顺序排序并去重
    STEPS=()
    for tok in "${ALL_STEPS[@]}"; do
        [[ " ${out[*]} " == *" $tok "* ]] && STEPS+=("$tok")
    done
    [ ${#STEPS[@]} -gt 0 ]
}

key_fingerprint() {
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -lf - <<<"$1" 2>/dev/null | awk '{print $2, $NF}'
    else
        awk '{print $1, $3}' <<<"$1"
    fi
}

# choose_url VAR "标题" "当前值" "名称1|URL1" "名称2|URL2" ...（最后自动追加「自定义」）
choose_url() {
    local __var=$1 __title=$2 __cur=$3 __def="" __n=0 __pick __u __i
    shift 3
    local -a labels=() urls=()
    for __i in "$@"; do
        __n=$((__n + 1))
        labels+=("${__i%%|*}  ${__i#*|}"); urls+=("${__i#*|}")
        [ "${__i#*|}" = "$__cur" ] && __def=$__n
    done
    labels+=("自定义地址"); __n=$((__n + 1))
    [ -n "$__def" ] || __def=$__n
    choose __pick "$__title" "$__def" "${labels[@]}"
    if [ "$__pick" -eq "$__n" ]; then
        while :; do
            ask __u "输入地址" "$__cur"
            [[ $__u =~ ^https?://[^[:space:]]+$ ]] && break
            echo "  地址需以 http:// 或 https:// 开头"
        done
        printf -v "$__var" '%s' "${__u%/}"
    else
        printf -v "$__var" '%s' "${urls[$((__pick - 1))]}"
    fi
}

wizard() {
    echo
    log "交互式向导（直接回车使用方括号中的默认值，Ctrl+C 随时退出）"
    info "正在检测各项当前状态 ..."
    probe_status
    echo
    echo "  ${C_B}1. 选择步骤${C_0}"
    print_step_table
    local sel def="a"
    # 命令行给了 --only/--skip 时，以它们选中的步骤作为默认值
    [ ${#STEPS[@]} -eq ${#ALL_STEPS[@]} ] || def="${STEPS[*]}"
    while :; do
        ask sel "要执行的步骤（序号或名称，空格分隔；a = 全部，可重复执行）" "$def"
        parse_step_selection "$sel" && break
        echo "  无法识别: $sel"
    done

    echo
    echo "  ${C_B}2. 参数${C_0}"
    local v
    if step_selected user || step_selected ssh || step_selected shell; then
        while :; do
            ask v "管理用户名" "$BL_USER"
            [[ $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
            echo "  用户名只能包含小写字母、数字、_ 和 -"
        done
        BL_USER=$v
    fi
    if step_selected hostname; then
        while :; do
            ask v "主机名（可为 FQDN，如 web-01.example.com）" "${BL_HOSTNAME:-$(hostname)}"
            valid_hostname "$v" && break
            echo "  主机名不合法（字母/数字/连字符，每段 ≤63）"
        done
        BL_HOSTNAME=${v,,}
    fi
    if step_selected apt; then
        local -a opts=("Debian 官方|http://deb.debian.org/debian")
        case $DMI_VENDOR in
            *Alibaba*) opts+=("阿里云内网镜像|http://mirrors.cloud.aliyuncs.com/debian") ;;
            *Tencent*) opts+=("腾讯云内网镜像|http://mirrors.tencentyun.com/debian") ;;
        esac
        opts+=("阿里云公网镜像|https://mirrors.aliyun.com/debian" "清华大学镜像|https://mirrors.tuna.tsinghua.edu.cn/debian")
        choose_url APT_MIRROR "Debian 主仓库（${CODENAME}）" "$APT_MIRROR" "${opts[@]}"
        # 安全仓库默认跟随主仓库所在镜像站
        case $APT_MIRROR in
            http://deb.debian.org/debian) v="http://security.debian.org/debian-security" ;;
            */debian) v="${APT_MIRROR%/debian}/debian-security" ;;
            *) v=$APT_SECURITY_MIRROR ;;
        esac
        ask APT_SECURITY_MIRROR "安全更新仓库" "$v"
        APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR%/}
        if ask_yn "启用 backports 仓库?" "$( [ "$APT_BACKPORTS" = yes ] && echo y || echo n )"; then APT_BACKPORTS=yes; else APT_BACKPORTS=no; fi
        if ask_yn "启用源码仓库 deb-src?" "$( [ "$APT_WITH_SRC" = yes ] && echo y || echo n )"; then APT_WITH_SRC=yes; else APT_WITH_SRC=no; fi
    fi
    if step_selected docker; then
        choose_url DOCKER_MIRROR "Docker 仓库" "$DOCKER_MIRROR" \
            "Docker 官方|https://download.docker.com/linux/debian" \
            "阿里云镜像|https://mirrors.aliyun.com/docker-ce/linux/debian" \
            "清华大学镜像|https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian"
    fi
    if step_selected user || step_selected ssh; then
        local k
        if [ "$BL_USER" = "$DEFAULT_USER" ]; then
            for k in "${DEFAULT_USER_KEYS[@]}"; do info "将为 $BL_USER 安装默认公钥: $(key_fingerprint "$k")"; done
        fi
        info "如需再添加公钥，逐行粘贴（ssh-ed25519 AAAA... 格式），直接回车结束:"
        while :; do
            IFS= read -r -p "  公钥> " k </dev/tty || k=""
            [ -n "$k" ] || break
            if [ -n "$(printf '%s\n' "$k" | extract_keys)" ]; then
                SSH_KEYS+=("$k"); info "已加入: $(key_fingerprint "$k")"
            else
                echo "  不是有效的公钥行，已忽略"
            fi
        done
    fi

    echo
    echo "  ${C_B}3. 确认${C_0}"
    local s
    for s in "${STEPS[@]}"; do printf '    • %-9s %s\n' "$s" "$(step_title "$s")"; done
    echo
    step_selected user     && info "用户:     $BL_USER（额外公钥 ${#SSH_KEYS[@]} 把）"
    step_selected hostname && info "主机名:   $BL_HOSTNAME"
    step_selected apt      && info "apt:      $APT_MIRROR | $APT_SECURITY_MIRROR（backports: $APT_BACKPORTS, deb-src: $APT_WITH_SRC）"
    step_selected docker   && info "docker:   $DOCKER_MIRROR"
    if step_selected ssh; then
        warn "SSH 将禁用密码登录：执行后请保持当前会话，另开终端确认 $BL_USER 能用公钥登录"
    fi
    echo
    ask_yn "确认执行?" y || { info "已取消，未做任何修改"; exit 0; }
}

menu() {
    local op
    while :; do
        echo
        choose op "请选择操作" 1 \
            "初始化 / 重新对齐（交互式向导）" \
            "验收检查（只读）" \
            "安装到 $SELF_INSTALL_PATH" \
            "版本信息" \
            "退出"
        case $op in
            1) do_apply ;;
            2) run_checks || true ;;
            3) install_self ;;
            4) print_version ;;
            5) exit 0 ;;
        esac
    done
}

do_apply() {
    if [ "$INTERACTIVE" = "yes" ]; then
        wizard
    else
        mirror_hint
    fi
    wait_cloud_init

    local s i=0
    for s in "${STEPS[@]}"; do
        i=$((i + 1))
        log "[$i/${#STEPS[@]}] $s — $(step_title "$s")"
        "step_$s"
    done

    log "持久化"
    install_self
    save_conf
    [ -n "$BACKUP_DIR" ] && info "被修改文件的原始版本备份在: $BACKUP_DIR"
    echo
    if run_checks; then exit 0; else exit 1; fi
}

# ================================================================== 入口 ===
main() {
    local cmd=${1:-}
    case $cmd in
        apply|check|heal|install|menu) shift ;;
        -h|--help|help) usage; exit 0 ;;
        -V|--version|version) resolve_build_info; print_version; exit 0 ;;
        ""|-*) cmd="menu" ;;   # 无子命令：交互菜单（可带参数作为默认值）
        *) die "未知子命令: $cmd（--help 查看用法）" ;;
    esac
    parse_args "$@"
    resolve_build_info
    require_root
    export PATH="$SAFE_PATH:$PATH" LC_ALL=C.UTF-8

    case $cmd in
        heal)    do_heal; exit 0 ;;
        install) log "安装 debian-baseline"; install_self; exit 0 ;;
    esac

    load_os
    load_conf
    apply_overrides
    detect_env
    select_steps

    if [ "$cmd" = "menu" ] && [ "$INTERACTIVE" != "yes" ]; then
        usage; exit 0
    fi
    print_env

    case $cmd in
        check) if run_checks; then exit 0; else exit 1; fi ;;
        apply) do_apply ;;
        menu)  menu ;;
    esac
}

main "$@"
