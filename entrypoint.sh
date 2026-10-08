#!/usr/bin/env bash
# =========================================================
# komari + Argo Tunnel 一体化容器入口脚本
#
# 功能：
#   1. 启动 Komari
#   2. 启动 Cloudflare Tunnel / Argo Tunnel
#   3. Cloudflared 异常退出后自动重启
#   4. Komari 异常退出后让容器退出，由 Docker restart 策略负责恢复
#   5. GitHub 数据持久化
#   6. 定时备份
#   7. 容器退出时执行最终备份
#
# 环境变量含义见仓库 README
# =========================================================

set -uo pipefail

WORK_DIR="${WORK_DIR:-/app}"
DATA_DIR="${DATA_DIR:-/app/data}"
KOMARI_PORT="${KOMARI_PORT:-25774}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"

# Cloudflared 异常退出后的重启间隔
ARGO_RESTART_DELAY="${ARGO_RESTART_DELAY:-5}"

# 初始化 PID 变量
KOMARI_PID=""
ARGO_PID=""

# 防止退出处理函数重复执行
SHUTTING_DOWN=0

mkdir -p "$DATA_DIR"

# 确保预先生成 komari 官方校验所需的标识文件
# 防止备份包损坏/校验失败
touch "${DATA_DIR}/komari-backup-markup"

log() {
  echo -e "[$(date '+%F %T')] $*"
}

# ---------------------------------------------------------
# 0. 实例标识
# ---------------------------------------------------------
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
SUB_NAME="${SUB_NAME:-komari-node}"

log "实例标识 UUID=${UUID} SUB_NAME=${SUB_NAME}"

echo "${UUID}" > "${DATA_DIR}/.instance_uuid"

# ---------------------------------------------------------
# 1. 下载加速前缀
# ---------------------------------------------------------
gh_dl() {
  local url="$1"

  if [ -n "${CF_IP:-}" ]; then
    echo "https://${CF_IP}/${url}"
  else
    echo "${url}"
  fi
}

# ---------------------------------------------------------
# 2. 安装 cloudflared
# ---------------------------------------------------------
install_cloudflared() {
  if [ -x "$CLOUDFLARED_BIN" ]; then
    log "cloudflared 已存在：${CLOUDFLARED_BIN}"
    return 0
  fi

  local arch

  case "$(uname -m)" in
    x86_64)
      arch="amd64"
      ;;
    aarch64)
      arch="arm64"
      ;;
    armv7l)
      arch="arm"
      ;;
    *)
      log "不支持的架构: $(uname -m)"
      return 1
      ;;
  esac

  local origin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  local tmp_file="/tmp/cloudflared.download"

  # -------------------------------------------------------
  # 优先使用 CF_IP 加速地址
  # -------------------------------------------------------
  if [ -n "${CF_IP:-}" ]; then
    local mirror_url

    mirror_url="$(gh_dl "$origin_url")"

    log "下载 cloudflared（加速）: $mirror_url"

    if curl -fsSL \
      --connect-timeout 10 \
      -o "$tmp_file" \
      "$mirror_url"; then

      mv "$tmp_file" "$CLOUDFLARED_BIN"
      chmod +x "$CLOUDFLARED_BIN"

      log "cloudflared 安装成功"
      return 0
    fi

    log "加速下载失败，回退到官方地址重试"
  fi

  # -------------------------------------------------------
  # 官方源
  # -------------------------------------------------------
  log "下载 cloudflared（官方源）: $origin_url"

  if curl -fsSL \
    --connect-timeout 10 \
    -o "$tmp_file" \
    "$origin_url"; then

    mv "$tmp_file" "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"

    log "cloudflared 安装成功"
    return 0
  fi

  log "cloudflared 下载失败：加速源和官方源均不可用，请检查出站网络"

  return 1
}

# ---------------------------------------------------------
# 3. GitHub 数据持久化：启动前还原
# ---------------------------------------------------------
setup_git_persistence() {

  if [ -z "${GH_PAT:-}" ] ||
     [ -z "${GH_REPO:-}" ] ||
     [ -z "${GH_USER:-}" ]; then

    log "未提供完整的 GH_USER/GH_PAT/GH_REPO，跳过 GitHub 持久化备份"
    return 0
  fi

  if [[ "${GH_REPO}" != */* ]]; then

    log "警告：GH_REPO='${GH_REPO}' 格式不对"
    log "必须是 '用户名/仓库名'，已跳过 GitHub 持久化备份"

    return 0
  fi

  git config --global user.name "${GH_USER}"

  git config --global user.email \
    "${GH_EMAIL:-${GH_USER}@users.noreply.github.com}"

  git config --global credential.helper store

  echo "https://${GH_USER}:${GH_PAT}@github.com" \
    > ~/.git-credentials

  local repo_url
  repo_url="https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git"

  local branch="${SUB_NAME:-main}"

  log "检查远程备份仓库 ${GH_REPO}@${branch} 状态..."

  local remote_refs

  remote_refs=$(
    git ls-remote --heads "$repo_url" "$branch" 2>/dev/null || true
  )

  if [ -z "$remote_refs" ]; then

    log "检测到远程分支不存在或仓库为空"
    log "跳过数据恢复，直接以全新数据启动"

  else

    log "检测到远程备份存在，准备下载并还原历史数据..."

    if /usr/local/bin/restore.sh; then
      log "历史数据还原成功！"
    else
      log "数据还原过程出现警告/异常，将继续以当前数据启动"
    fi

  fi

  touch "${DATA_DIR}/komari-backup-markup"
}

# ---------------------------------------------------------
# 3.1 定时备份
#
# 使用 Alpine / BusyBox 自带的 crond
#
# BusyBox crond 使用：
#   /etc/crontabs/root
#
# 而不是：
#   /etc/cron.d/
#
# 只要配置：
#   GH_USER
#   GH_PAT
#   GH_REPO
#
# 就会持续执行备份。
# ---------------------------------------------------------
setup_cron_backup() {

  if [ -z "${GH_PAT:-}" ] ||
     [ -z "${GH_REPO:-}" ] ||
     [ -z "${GH_USER:-}" ]; then

    log "缺少 GH_USER / GH_PAT / GH_REPO，跳过配置定时备份"

    return 0
  fi

  if [[ "${GH_REPO}" != */* ]]; then

    log "GH_REPO 格式不对，跳过配置定时备份"

    return 0
  fi

  mkdir -p /etc/crontabs

  local cron_file="/etc/crontabs/root"
  local cron_log="${DATA_DIR}/backup_cron.log"

  touch "$cron_file"
  touch "$cron_log"

  # -------------------------------------------------------
  # 去重
  # -------------------------------------------------------
  grep -v "backup.sh" "$cron_file" \
    > "${cron_file}.tmp" 2>/dev/null || true

  mv "${cron_file}.tmp" "$cron_file"

  # -------------------------------------------------------
  # 写入环境变量和定时任务
  # -------------------------------------------------------
  {
    echo "GH_PAT=${GH_PAT}"
    echo "GH_REPO=${GH_REPO}"
    echo "GH_USER=${GH_USER}"
    echo "SUB_NAME=${SUB_NAME:-main}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # 每 2 小时执行一次
    echo "* */2 * * * /usr/local/bin/backup.sh >> ${cron_log} 2>&1"

  } >> "$cron_file"

  # -------------------------------------------------------
  # 检查 crond
  # -------------------------------------------------------
  if ! command -v crond >/dev/null 2>&1; then

    log "错误：容器内未找到 crond 命令"
    log "请确认基础镜像自带 BusyBox crond"

    return 1
  fi

  # -------------------------------------------------------
  # 启动 crond
  # -------------------------------------------------------
  if ! pgrep -x crond >/dev/null 2>&1; then

    crond -b -l 8

    log "已启动 crond 后台守护进程"

  else

    log "crond 已在运行，无需重复启动"

  fi

  log "已写入定时备份任务到 ${cron_file}"
  log "备份周期：每 2 小时一次"

  # -------------------------------------------------------
  # 启动后 60 秒立即备份一次
  # -------------------------------------------------------
  (
    sleep 60

    if [ "$SHUTTING_DOWN" -eq 0 ]; then

      /usr/local/bin/backup.sh \
        >> "$cron_log" 2>&1 \
        || log "首次即时备份失败，等待下个 cron 周期重试"

    fi

  ) &
}

# ---------------------------------------------------------
# 4. komari 面板账号/令牌映射
# ---------------------------------------------------------

export ADMIN_USERNAME="${GH_USER:-admin}"

if [ -n "${DASH_TOKEN:-}" ]; then
  export ADMIN_PASSWORD="${DASH_TOKEN}"
fi

if [ -n "${API_TOKEN:-}" ]; then

  echo "${API_TOKEN}" > "${DATA_DIR}/.api_token"

  log "已写入 API_TOKEN 到 ${DATA_DIR}/.api_token"
fi

if [ -n "${GH_CLIENTID:-}" ]; then
  export OAUTH_CLIENT_ID="${GH_CLIENTID}"
fi

if [ -n "${GH_CLIENTSECRET:-}" ]; then
  export OAUTH_CLIENT_SECRET="${GH_CLIENTSECRET}"
fi

# ---------------------------------------------------------
# 5. 启动 komari 面板
# ---------------------------------------------------------
start_komari() {

  log "启动 komari 面板"
  log "监听地址：0.0.0.0:${KOMARI_PORT}"

  /app/komari server \
    -l "0.0.0.0:${KOMARI_PORT}" &

  KOMARI_PID=$!

  log "Komari PID=${KOMARI_PID}"
}

# ---------------------------------------------------------
# 6. 启动 Argo / Cloudflare Tunnel
#
# 重要：
#
# 原来的代码：
#
#   cloudflared ... &
#
# 如果 cloudflared 自己退出，
# 没有任何东西会重新启动它。
#
# 现在改成：
#
#   while true
#       cloudflared
#       如果退出
#       等待 5 秒
#       再启动
#   done
#
# 因此 Cloudflare Tunnel 会自动恢复。
# ---------------------------------------------------------

start_argo() {

  if [ -z "${ARGO_AUTH:-}" ]; then

    log "未设置 ARGO_AUTH"
    log "跳过 Argo 隧道，仅本地监听 ${KOMARI_PORT} 端口"

    return 0
  fi

  # -------------------------------------------------------
  # 安装 / 检查 cloudflared
  # -------------------------------------------------------
  if ! install_cloudflared; then

    log "cloudflared 安装失败"

    return 1
  fi

  # -------------------------------------------------------
  # JSON 凭证模式
  # -------------------------------------------------------
  if echo "${ARGO_AUTH}" | jq -e . >/dev/null 2>&1; then

    log "检测到 ARGO_AUTH 为 JSON 凭证"
    log "使用具名隧道 + 自定义 ingress 模式"

    mkdir -p /etc/cloudflared

    echo "${ARGO_AUTH}" \
      > /etc/cloudflared/tunnel.json

    TUNNEL_ID=$(
      echo "${ARGO_AUTH}" |
      jq -r '.TunnelID // .tunnel_id // empty'
    )

    if [ -z "$TUNNEL_ID" ]; then

      log "错误：无法从 ARGO_AUTH 中读取 TunnelID"

      return 1
    fi

    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN:-localhost}
    service: http://localhost:${KOMARI_PORT}

  - service: http_status:404
EOF

    log "Cloudflare Tunnel 配置已生成"
    log "Tunnel ID=${TUNNEL_ID}"

    # -----------------------------------------------------
    # JSON 模式守护循环
    # -----------------------------------------------------
    (
      while true; do

        if [ "$SHUTTING_DOWN" -ne 0 ]; then
          break
        fi

        log "启动 cloudflared（JSON 凭证模式）..."

        "$CLOUDFLARED_BIN" \
          tunnel \
          --config /etc/cloudflared/config.yml \
          run

        EXIT_CODE=$?

        if [ "$SHUTTING_DOWN" -ne 0 ]; then
          break
        fi

        log "cloudflared 已退出"
        log "退出码=${EXIT_CODE}"
        log "${ARGO_RESTART_DELAY} 秒后自动重新启动..."

        sleep "$ARGO_RESTART_DELAY"

      done

    ) &

    ARGO_PID=$!

  else

    # -----------------------------------------------------
    # Token 模式
    # -----------------------------------------------------
    log "检测到 ARGO_AUTH 为 Token 模式"
    log "使用远程管理隧道"

    # -----------------------------------------------------
    # Token 模式守护循环
    # -----------------------------------------------------
    (
      while true; do

        if [ "$SHUTTING_DOWN" -ne 0 ]; then
          break
        fi

        log "启动 cloudflared Tunnel..."

        "$CLOUDFLARED_BIN" \
          tunnel run \
          --token "${ARGO_AUTH}"

        EXIT_CODE=$?

        if [ "$SHUTTING_DOWN" -ne 0 ]; then
          break
        fi

        log "cloudflared 已退出"
        log "退出码=${EXIT_CODE}"
        log "${ARGO_RESTART_DELAY} 秒后自动重新启动..."

        sleep "$ARGO_RESTART_DELAY"

      done

    ) &

    ARGO_PID=$!

  fi

  log "Argo 隧道守护进程已启动"
  log "ARGO PID=${ARGO_PID}"
  log "外部访问地址：https://${ARGO_DOMAIN:-localhost}"
}

# ---------------------------------------------------------
# 7. 检查 Komari 是否仍然运行
# ---------------------------------------------------------
is_komari_running() {

  if [ -z "${KOMARI_PID}" ]; then
    return 1
  fi

  kill -0 "$KOMARI_PID" 2>/dev/null
}

# ---------------------------------------------------------
# 8. 优雅退出
#
# 无论 NO_AUTO_RENEW 是否存在，
# 都尝试进行最后一次备份。
# ---------------------------------------------------------
term_handler() {

  # 防止重复执行
  if [ "$SHUTTING_DOWN" -ne 0 ]; then
    return
  fi

  SHUTTING_DOWN=1

  log "========================================"
  log "收到退出信号"
  log "开始执行容器关闭流程"
  log "========================================"

  # -------------------------------------------------------
  # 最终备份
  # -------------------------------------------------------
  if [ -n "${GH_PAT:-}" ] &&
     [ -n "${GH_REPO:-}" ]; then

    log "执行最终数据备份..."

    touch "${DATA_DIR}/komari-backup-markup" 2>/dev/null || true

    /usr/local/bin/backup.sh || true

    log "最终备份处理完成"
  fi

  # -------------------------------------------------------
  # 停止 cloudflared 守护进程
  # -------------------------------------------------------
  if [ -n "${ARGO_PID}" ]; then

    if kill -0 "$ARGO_PID" 2>/dev/null; then

      log "停止 cloudflared 守护进程 PID=${ARGO_PID}"

      kill "$ARGO_PID" 2>/dev/null || true

    fi
  fi

  # -------------------------------------------------------
  # 停止 Komari
  # -------------------------------------------------------
  if [ -n "${KOMARI_PID}" ]; then

    if kill -0 "$KOMARI_PID" 2>/dev/null; then

      log "停止 Komari PID=${KOMARI_PID}"

      kill "$KOMARI_PID" 2>/dev/null || true

    fi
  fi

  log "容器退出"

  exit 0
}

# ---------------------------------------------------------
# 9. 信号处理
# ---------------------------------------------------------
trap term_handler SIGTERM SIGINT

# ---------------------------------------------------------
# 10. 主流程
# ---------------------------------------------------------

log "========================================"
log "Komari + Cloudflare Tunnel 启动"
log "========================================"

# ---------------------------------------------------------
# 恢复历史数据
# ---------------------------------------------------------
setup_git_persistence

# ---------------------------------------------------------
# 启动 Komari
# ---------------------------------------------------------
start_komari

# ---------------------------------------------------------
# 等待一小段时间，让 Komari 完成初始化
# ---------------------------------------------------------
sleep 2

# ---------------------------------------------------------
# 启动 Cloudflare Tunnel
# ---------------------------------------------------------
if ! start_argo; then

  log "警告：Cloudflare Tunnel 启动失败"
  log "Komari 仍会继续运行"

fi

# ---------------------------------------------------------
# 启动定时备份
# ---------------------------------------------------------
setup_cron_backup

log "========================================"
log "所有服务启动完成"
log "Komari PID=${KOMARI_PID}"
log "Argo PID=${ARGO_PID:-未启动}"
log "Komari Port=${KOMARI_PORT}"
log "========================================"

# ---------------------------------------------------------
# 11. 主进程监控
#
# 这里不再单纯：
#
#   wait "$KOMARI_PID"
#
# 而是持续检查 Komari。
#
# 如果 Komari 崩溃：
#
#   Komari退出
#       ↓
#   entrypoint发现
#       ↓
#   执行最终退出
#       ↓
#   Docker restart policy
#       ↓
#   整个容器重新启动
#
# Cloudflared 则由 start_argo() 自己负责自动重连。
# ---------------------------------------------------------

while true; do

  # -------------------------------------------------------
  # 如果收到关闭信号
  # -------------------------------------------------------
  if [ "$SHUTTING_DOWN" -ne 0 ]; then
    break
  fi

  # -------------------------------------------------------
  # 检查 Komari
  # -------------------------------------------------------
  if ! is_komari_running; then

    log "========================================"
    log "检测到 Komari 进程已经退出"
    log "PID=${KOMARI_PID}"
    log "准备退出容器，由 Docker 负责重新启动"
    log "========================================"

    break
  fi

  # 每 10 秒检查一次
  sleep 10

done

# ---------------------------------------------------------
# Komari 异常退出
# ---------------------------------------------------------

if [ "$SHUTTING_DOWN" -eq 0 ]; then

  log "Komari 已停止，执行最终退出处理"

  # 手动调用退出处理
  term_handler

fi

exit 1
