#!/usr/bin/env bash

set -u
set -o pipefail

WORKDIR="/home/backupmanager/import_mysql8"
ENV_FILE="$WORKDIR/.env"
LOGDIR="$WORKDIR/logs"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: File konfigurasi tidak ditemukan: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

MAIN_LOG="$LOGDIR/main_${TIMESTAMP}.log"
MYSQL_STDOUT_LOG="$LOGDIR/mysql_stdout_${TIMESTAMP}.log"
MYSQL_ERROR_LOG="$LOGDIR/mysql_error_${TIMESTAMP}.log"
IMPORT_ERROR_ONLY_LOG="$LOGDIR/import_error_only_${TIMESTAMP}.log"
IMPORT_WARNING_ONLY_LOG="$LOGDIR/import_warning_only_${TIMESTAMP}.log"
NON_INNODB_LOG="$LOGDIR/non_innodb_${TIMESTAMP}.log"
ENGINE_SUMMARY_LOG="$LOGDIR/engine_summary_${TIMESTAMP}.log"
ERROR_SUMMARY_LOG="$LOGDIR/error_summary_${TIMESTAMP}.log"

mkdir -p "$LOGDIR"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$MAIN_LOG"
}

log "=========================================="
log "IMPORT MYSQL 5 DUMP TO MYSQL 8"
log "Database      : $DB_NAME"
log "Backup file   : $BACKUP_FILE"
log "Workdir       : $WORKDIR"
log "Main log      : $MAIN_LOG"
log "MySQL stdout  : $MYSQL_STDOUT_LOG"
log "MySQL error   : $MYSQL_ERROR_LOG"
log "=========================================="

if [ ! -f "$BACKUP_FILE" ]; then
    log "ERROR: File backup tidak ditemukan: $BACKUP_FILE"
    exit 1
fi

log "Cek file backup:"
ls -lh "$BACKUP_FILE" | tee -a "$MAIN_LOG"

log "Cek koneksi MySQL..."
MYSQL_PWD="$DB_PASS" mysqladmin -u"$DB_USER" ping >> "$MAIN_LOG" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: MySQL tidak bisa diakses. Cek user/password/service MySQL."
    exit 1
fi

log "Cek database tujuan..."
MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -N -e "SHOW DATABASES LIKE '${DB_NAME}';" | grep -w "$DB_NAME" >> "$MAIN_LOG" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Database $DB_NAME belum ada."
    log "Buat dulu dengan:"
    log "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    exit 1
fi

log "Cek kapasitas disk..."
df -h | tee -a "$MAIN_LOG"

log "Mulai import."
log "Mode:"
log "- gzip stream"
log "- convert ENGINE=MyISAM menjadi ENGINE=InnoDB"
log "- convert TYPE=MyISAM menjadi ENGINE=InnoDB"
log "- --force aktif, error SQL tidak menghentikan import"
log "- foreign_key_checks=0 dan unique_checks=0 hanya untuk sesi import"

START_TIME=$(date +%s)

{
    echo "SET SESSION foreign_key_checks=0;"
    echo "SET SESSION unique_checks=0;"
    echo "SET SESSION sql_log_bin=0;"
    echo "SET SESSION innodb_strict_mode=0;"
    gzip -dc "$BACKUP_FILE" \
    | sed -E \
        -e 's/ENGINE[[:space:]]*=[[:space:]]*MyISAM/ENGINE=InnoDB/gI' \
        -e 's/TYPE[[:space:]]*=[[:space:]]*MyISAM/ENGINE=InnoDB/gI' \
        -e 's/ROW_FORMAT[[:space:]]*=[[:space:]]*FIXED/ROW_FORMAT=DYNAMIC/gI'
    echo "SET SESSION foreign_key_checks=1;"
    echo "SET SESSION unique_checks=1;"
} | pv \
| MYSQL_PWD="$DB_PASS" mysql \
    -u"$DB_USER" \
    --database="$DB_NAME" \
    --force \
    --show-warnings \
    --binary-mode=1 \
    --max_allowed_packet=1G \
    --default-character-set=utf8mb4 \
    1> "$MYSQL_STDOUT_LOG" \
    2> "$MYSQL_ERROR_LOG"

MYSQL_EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "Import stream selesai."
log "Exit code MySQL: $MYSQL_EXIT_CODE"
log "Durasi detik: $DURATION"

log "Pisahkan ERROR dan WARNING..."
grep -i "ERROR" "$MYSQL_ERROR_LOG" > "$IMPORT_ERROR_ONLY_LOG" || true
grep -i "Warning" "$MYSQL_ERROR_LOG" > "$IMPORT_WARNING_ONLY_LOG" || true

log "Buat ringkasan error..."
{
    echo "===== ERROR SUMMARY ====="
    echo "Tanggal       : $(date)"
    echo "Database      : $DB_NAME"
    echo "Backup file   : $BACKUP_FILE"
    echo "MySQL exit    : $MYSQL_EXIT_CODE"
    echo ""

    echo "===== TOTAL ERROR ====="
    grep -ci "ERROR" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== TOTAL WARNING ====="
    grep -ci "Warning" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== ERROR BERDASARKAN NOMOR ERROR MYSQL ====="
    grep -oiE "ERROR [0-9]+" "$MYSQL_ERROR_LOG" | sort | uniq -c | sort -nr || true
    echo ""

    echo "===== ERROR DETAIL ====="
    grep -i "ERROR" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== WARNING DETAIL ====="
    grep -i "Warning" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== KEMUNGKINAN MASALAH TABLE ====="
    grep -iE "table|doesn't exist|already exists|duplicate|foreign key|constraint|row size|key|index" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== KEMUNGKINAN MASALAH COLUMN ====="
    grep -iE "column|field|data too long|incorrect|invalid|truncated|unknown column" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== KEMUNGKINAN MASALAH COLLATION / CHARSET ====="
    grep -iE "collation|character set|charset|utf8|utf8mb4" "$MYSQL_ERROR_LOG" || true
    echo ""

    echo "===== KEMUNGKINAN MASALAH SYNTAX ====="
    grep -iE "syntax|near" "$MYSQL_ERROR_LOG" || true
    echo ""
} > "$ERROR_SUMMARY_LOG"

log "Cek engine tabel..."
MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "
SELECT 
    ENGINE,
    COUNT(*) AS total
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
AND TABLE_TYPE='BASE TABLE'
GROUP BY ENGINE;
" | tee "$ENGINE_SUMMARY_LOG" >> "$MAIN_LOG"

log "Cek tabel yang masih bukan InnoDB..."
MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "
SELECT 
    TABLE_NAME,
    ENGINE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
AND TABLE_TYPE='BASE TABLE'
AND ENGINE <> 'InnoDB';
" | tee "$NON_INNODB_LOG" >> "$MAIN_LOG"

log "Cek total tabel dan ukuran database..."
MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "
SELECT COUNT(*) AS total_tables
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
AND TABLE_TYPE='BASE TABLE';

SELECT 
    table_schema AS database_name,
    ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS size_gb
FROM information_schema.tables
WHERE table_schema='${DB_NAME}'
GROUP BY table_schema;
" | tee -a "$MAIN_LOG"

log "=========================================="
log "IMPORT SELESAI"
log "Main log             : $MAIN_LOG"
log "MySQL stdout log     : $MYSQL_STDOUT_LOG"
log "MySQL error log      : $MYSQL_ERROR_LOG"
log "Error only log       : $IMPORT_ERROR_ONLY_LOG"
log "Warning only log     : $IMPORT_WARNING_ONLY_LOG"
log "Error summary log    : $ERROR_SUMMARY_LOG"
log "Non InnoDB log       : $NON_INNODB_LOG"
log "Engine summary log   : $ENGINE_SUMMARY_LOG"
log "=========================================="

if [ "$MYSQL_EXIT_CODE" -ne 0 ]; then
    log "CATATAN: Exit code tidak 0. Karena --force aktif, sebagian besar error SQL tetap dilewati, tapi cek error_summary log."
else
    log "Import selesai dengan exit code 0."
fi
