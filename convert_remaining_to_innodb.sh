#!/usr/bin/env bash

set -u

WORKDIR="/home/backupmanager/import_mysql8"
ENV_FILE="$WORKDIR/.env"
LOGDIR="$WORKDIR/logs"

source "$ENV_FILE"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="$LOGDIR/convert_remaining_to_innodb_${TIMESTAMP}.log"
FAILED_LOG="$LOGDIR/convert_failed_${TIMESTAMP}.log"

mkdir -p "$LOGDIR"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

log "Mulai convert sisa table non-InnoDB ke InnoDB."
log "Database: $DB_NAME"

MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -N -e "
SELECT TABLE_NAME
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
AND TABLE_TYPE='BASE TABLE'
AND ENGINE <> 'InnoDB';
" | while read -r TABLE_NAME; do

    if [ -z "$TABLE_NAME" ]; then
        continue
    fi

    log "Converting: $TABLE_NAME"

    MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" "$DB_NAME" --force -e "
    ALTER TABLE \`${TABLE_NAME}\` ENGINE=InnoDB;
    " >> "$LOGFILE" 2>> "$FAILED_LOG"

    if [ $? -eq 0 ]; then
        log "OK: $TABLE_NAME"
    else
        log "FAILED: $TABLE_NAME"
        echo "$TABLE_NAME" >> "$FAILED_LOG"
    fi

done

log "Cek ulang engine:"
MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "
SELECT ENGINE, COUNT(*) AS total
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
AND TABLE_TYPE='BASE TABLE'
GROUP BY ENGINE;
" | tee -a "$LOGFILE"

log "Selesai."
log "Log gagal convert: $FAILED_LOG"
