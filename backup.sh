#!/usr/bin/env bash
# 全量备份 /app/data 到 GitHub
# SQLite 数据库使用安全 backup，不直接复制运行中的 db

set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
BACKUP_DIR="/tmp/komari-backup"
BRANCH="${SUB_NAME:-main}"

METRICS_DB="${DATA_DIR}/metrics.db"
SQLITE_BACKUP="${DATA_DIR}/metrics.db.backup"


if [ -z "${GH_PAT:-}" ] || \
   [ -z "${GH_REPO:-}" ] || \
   [ -z "${GH_USER:-}" ]; then

    echo "缺少 GH_USER/GH_PAT/GH_REPO，无法备份"
    exit 1
fi


if [[ "${GH_REPO}" != */* ]]; then
    echo "GH_REPO='${GH_REPO}' 格式错误"
    exit 1
fi


#####################################
# 1. 创建 SQLite 一致性备份
#####################################

if [ -f "$METRICS_DB" ]; then

    echo "检测到 metrics.db，开始 SQLite 安全备份..."

    # checkpoint WAL
    sqlite3 "$METRICS_DB" \
        "PRAGMA wal_checkpoint(FULL);" \
        || echo "wal checkpoint失败，继续"


    # SQLite官方backup方式
    rm -f "$SQLITE_BACKUP"

    sqlite3 "$METRICS_DB" \
        ".backup '${SQLITE_BACKUP}'"


    # 检查备份完整性
    CHECK_RESULT=$(sqlite3 "$SQLITE_BACKUP" \
        "PRAGMA integrity_check;" 2>&1)


    if [ "$CHECK_RESULT" != "ok" ]; then

        echo "ERROR:"
        echo "SQLite备份检查失败"
        echo "$CHECK_RESULT"

        rm -f "$SQLITE_BACKUP"

        exit 1
    fi


    echo "SQLite备份完成"

else
    echo "没有找到 metrics.db"
fi



#####################################
# 2. 拉取GitHub备份仓库
#####################################


rm -rf "$BACKUP_DIR"


if git clone \
    --depth 1 \
    --branch "$BRANCH" \
    "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git" \
    "$BACKUP_DIR" 2>/dev/null
then
    :

else

    mkdir -p "$BACKUP_DIR"

    cd "$BACKUP_DIR"

    git init -q

    git remote add origin \
    "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git"

    git checkout -q -b "$BRANCH"

fi



cd "$BACKUP_DIR"



#####################################
# 3. 创建恢复标记
#####################################


touch komari-backup-markup



#####################################
# 4. 复制普通文件
#####################################


echo "复制数据..."


find "$DATA_DIR" \
    -maxdepth 1 \
    ! -path "$DATA_DIR" \
    ! -name "metrics.db" \
    ! -name "metrics.db.backup" \
    -exec cp -rf {} ./ \;



#####################################
# 5. 使用安全数据库替换
#####################################


if [ -f "$SQLITE_BACKUP" ]; then

    echo "写入安全 metrics.db"

    cp "$SQLITE_BACKUP" ./metrics.db

fi



#####################################
# 6. 清理嵌套git
#####################################


find . \
    -mindepth 2 \
    -name ".git" \
    -exec rm -rf {} + 2>/dev/null || true



#####################################
# 7. 元数据
#####################################


echo "${UUID:-unknown}" > UUID

echo "$(date '+%F %T')" > last_backup.txt



#####################################
# 8. 提交
#####################################


git add -A


if git diff --cached --quiet; then

    echo "数据无变化，跳过提交"
    exit 0

fi


git commit \
    -q \
    -m "backup: ${SUB_NAME:-komari} $(date '+%F %T')"


git push \
    -q \
    -u origin "$BRANCH"



echo "备份完成 -> ${GH_REPO}@${BRANCH}"
