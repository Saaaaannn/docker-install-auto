#!/bin/bash

# +--------------------------------------------------+
# |         CentOS Docker 自动化安装脚本
# |   使用 yum-config-manager 添加仓库，解决 selinux |
# +--------------------------------------------------+

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

# 当前步骤（用于错误提示）
CURRENT_STEP="初始化"

# 错误处理函数
handle_error() {
    local exit_code=$?
    log_error "脚本执行失败！"
    log_error "当前步骤: $CURRENT_STEP"
    exit "$exit_code"
}
trap 'handle_error' ERR

# 检查是否为 root
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 用户运行！"
    exit 1
fi

# 获取系统信息（仅支持 CentOS 7）
OS=$(grep -E '^NAME=' /etc/os-release | cut -d'"' -f2)
VERSION_ID=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'"' -f2 | cut -d. -f1)

if [[ "$OS" != "CentOS Linux" ]] || [[ "$VERSION_ID" != "7" ]]; then
    log_error "本脚本仅支持 CentOS 7，当前系统: $OS $VERSION_ID"
    exit 1
fi

log_info "检测到系统: $OS $VERSION_ID"

# ============ 1. 设置阿里云 CentOS Base 源 ============

setup_centos_base_repo() {
    CURRENT_STEP="配置阿里云 CentOS Base 源"
    local repo_file="/etc/yum.repos.d/CentOS-Base.repo"
    local aliyun_repo_url="http://mirrors.aliyun.com/repo/Centos-7.repo"

    # 备份原文件
    if [[ -f "$repo_file" ]]; then
        mv "$repo_file" "$repo_file.backup_$(date +%s)" 2>/dev/null || true
        log_info "已备份原 CentOS-Base.repo"
    fi

    # 下载阿里云 repo
    if wget -O "$repo_file" "$aliyun_repo_url"; then
        log_info "成功下载阿里云 CentOS-7 Base 源"
        yum clean all >/dev/null 2>&1
        yum makecache fast >/dev/null 2>&1
        log_info "YUM 缓存已更新"
    else
        log_error "下载阿里云 Base 源失败，请检查网络"
        exit 1
    fi
}

# ============ 2. 使用 yum-config-manager 添加 Docker 仓库 ============

add_docker_repo() {
    CURRENT_STEP="添加 Docker CE 仓库"
    local docker_repo_url="https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"

    # 安装 yum-utils（提供 yum-config-manager）
    yum install -y yum-utils &>/dev/null || true

    # 使用指定命令添加仓库
    if yum-config-manager --add-repo "$docker_repo_url" >/dev/null 2>&1; then
        log_info "成功添加 Docker CE 仓库: $docker_repo_url"
    else
        log_error "添加 Docker 仓库失败"
        exit 1
    fi

    # 更新缓存
    yum makecache fast >/dev/null 2>&1
    log_info "Docker 仓库缓存已更新"
}

# ============ 3. 安装依赖包 ============

install_dependencies() {
    CURRENT_STEP="安装依赖包"
    log_info "安装依赖: yum-utils device-mapper-persistent-data lvm2"
    yum install -y yum-utils device-mapper-persistent-data lvm2
}

# ============ 4. 解决 container-selinux 依赖问题 ============

fix_container_selinux() {
    CURRENT_STEP="处理 container-selinux 依赖"
    
    if ! rpm -q container-selinux &>/dev/null; then
        log_warn "未安装 container-selinux，尝试安装 docker-ce-selinux..."

        # 创建临时 repo 用于安装旧版 docker-ce-selinux
        cat > /etc/yum.repos.d/docker-temp.repo << 'EOF'
[docker-temp]
name=Docker CE Temp Repo
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/7/x86_64/stable/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF

        if yum install -y docker-ce-selinux; then
            log_info "成功安装 docker-ce-selinux"
        else
            log_warn "无法安装 docker-ce-selinux，可能影响安装（继续尝试）"
        fi

        # 清理临时 repo
        rm -f /etc/yum.repos.d/docker-temp.repo
    else
        log_info "container-selinux 已安装，跳过。"
    fi
}

# ============ 5. 安装 Docker CE ============

install_docker_ce() {
    CURRENT_STEP="安装 Docker CE"
    
    if rpm -q docker-ce &>/dev/null; then
        log_info "Docker CE 已安装，跳过安装。"
        return 0
    fi

    log_info "正在安装 Docker CE..."
    if yum install -y docker-ce; then
        log_info "Docker CE 安装成功"
    else
        log_error "Docker CE 安装失败，请检查依赖和网络"
        exit 1
    fi

    # 启动并启用服务
    systemctl enable docker --now >/dev/null 2>&1
    log_info "Docker 服务已启用并启动"
}

# ============ 6. 配置镜像加速（幂等）============

setup_registry_mirror() {
    CURRENT_STEP="配置镜像加速源"
    local registry_dir="/etc/docker"
    local registry_file="$registry_dir/daemon.json"

    mkdir -p "$registry_dir"

    if [[ -f "$registry_file" ]] && grep -q "registry-mirrors" "$registry_file"; then
        log_info "镜像加速已配置，跳过。"
        return 0
    fi

    local mirrors=(
        "https://mirror.ccs.tencentyun.com"
        "https://docker.m.daocloud.io"
        "https://docker.mirrors.ustc.edu.cn"
        "http://hub-mirror.c.163.com"
    )

    log_info "配置镜像加速源（共 ${#mirrors[@]} 个）..."

    cat > "$registry_file" << EOF
{
  "registry-mirrors": [
$(printf '    "%s"' "${mirrors[0]}"; for ((i=1; i<${#mirrors[@]}; i++)); do printf ',\n    "%s"' "${mirrors[i]}"; done)
  ]
}
EOF

    systemctl daemon-reload
    systemctl restart docker
    log_info "镜像加速配置完成"
}

# ============ 7. 测试拉取 nginx ============

test_pull_nginx() {
    CURRENT_STEP="测试拉取 nginx:latest"
    
    if docker inspect nginx:latest &>/dev/null; then
        log_info "nginx:latest 镜像已存在，跳过拉取。"
        return 0
    fi

    log_info "正在拉取 nginx:latest..."
    if docker pull nginx:latest; then
        log_info "nginx 镜像拉取成功"
    else
        log_warn "nginx 拉取失败，可能影响后续使用"
    fi
}

# ============ 主流程 ============

main() {
    log_info "========================================"
    log_info "开始执行 Docker 安装"
    log_info "步骤：wget repo → yum-config-manager → makecache → install"
    log_info "========================================"

    setup_centos_base_repo
    add_docker_repo
    install_dependencies
    fix_container_selinux
    install_docker_ce
    setup_registry_mirror
    test_pull_nginx

    if command -v docker &>/dev/null; then
        log_info "Docker 安装成功: $(docker --version)"
    else
        log_error "Docker 安装失败：命令未找到"
        exit 1
    fi

    log_info "提示：可运行 'docker run -d -p 80:80 nginx' 启动测试容器"
    log_info "安装完成！"
}

main