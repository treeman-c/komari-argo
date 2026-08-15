#!/usr/bin/env bash
# 从 GH_REPO 恢复 Komari 数据
# 支持 SQLite 完整性检查，避免坏数据库覆盖运行环境

set -uo pipefail


DATA_DIR="${DATA_DIR:-/app/data}"
RESTORE_DIR="/tmp/komari-restore"
BRANCH="${SUB_NAME:-main}"


if [ -z "${GH_PAT:-}" ] || \
   [ -z "${GH_REPO:-}" ] || \
   [ -z "${GH_USER:-}" ]; then

    echo "缺少 GH_USER/GH_PAT/GH_REPO"
    exit 1

fi


if [[ "${GH_REPO}" != */* ]]; then

    echo "GH_REPO='${GH_REPO}' 格式错误，必须为 用户名/仓库名"

    exit 1

fi



#################################
# 1. 拉取备份仓库
#################################


rm -rf "$RESTORE_DIR"


if ! git clone \
    --depth 1 \
    --branch "$BRANCH" \
    "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git" \
    "$RESTORE_DIR"
then

    echo "远程仓库不存在，跳过恢复"

    exit 0

fi



#################################
# 2. 检查备份标记
#################################


if [ ! -f "${RESTORE_DIR}/komari-backup-markup" ]; then

    echo "不是Komari备份仓库，跳过"

    exit 0

fi



#################################
# 3. 检查SQLite备份
#################################


check_sqlite()
{

    local db="$1"


    if [ ! -f "$db" ]; then
        return 0
    fi


    echo "检查数据库: $db"


    RESULT=$(sqlite3 "$db" \
        "PRAGMA integrity_check;" \
        2>&1)


    if [ "$RESULT" != "ok" ]; then

        echo "数据库损坏:"
        echo "$RESULT"

        return 1

    fi


    return 0

}



#################################
# 4. 创建临时恢复目录
#################################


TMP_DATA="/tmp/komari-data-check"


rm -rf "$TMP_DATA"

mkdir -p "$TMP_DATA"



#################################
# 5. 复制备份到临时目录
#################################


find "$RESTORE_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name ".git" \
    -exec cp -rf {} "$TMP_DATA"/ \;



#################################
# 6. 检查 metrics.db
#################################


if ! check_sqlite "$TMP_DATA/metrics.db"; then

    echo "远程备份中的 metrics.db 损坏"
    echo "取消恢复，保护当前数据"

    exit 1

fi



#################################
# 7. 检查 komari.db
#################################


if ! check_sqlite "$TMP_DATA/komari.db"; then

    echo "远程备份中的 komari.db 损坏"
    echo "取消恢复"

    exit 1

fi



#################################
# 8. 清理旧数据库 WAL 文件
#################################


rm -f "$DATA_DIR"/*.db-wal
rm -f "$DATA_DIR"/*.db-shm



#################################
# 9. 备份当前数据
#################################


BACKUP_OLD="/tmp/komari-old-data"

rm -rf "$BACKUP_OLD"

mkdir -p "$BACKUP_OLD"


cp -rf "$DATA_DIR"/* "$BACKUP_OLD"/ 2>/dev/null || true



#################################
# 10. 正式恢复
#################################


find "$TMP_DATA" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec cp -rf {} "$DATA_DIR"/ \;



#################################
# 11. 清理嵌套 git
#################################


find "$DATA_DIR" \
    -mindepth 1 \
    -name ".git" \
    -exec rm -rf {} + 2>/dev/null || true



echo "历史数据恢复完成"

exit 0
