#!/usr/bin/env bash
# Run as root (or with sudo) to allow logrotate -d validation.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail() { echo -e "  ${RED}✗${RESET}  $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}!${RESET}  $*"; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

# Mirrors retention_days in roles/log_retention/defaults/main.yml. Override when
# the role was applied with a different value: RETENTION_DAYS=90 ./verify.sh
RETENTION_DAYS="${RETENTION_DAYS:-180}"

# Detect locale: use Traditional Chinese when LANG/LC_ALL is zh_TW or zh_HK
_locale="${LC_ALL:-${LANG:-}}"
if [[ $_locale == zh_TW* || $_locale == zh_HK* ]]; then
    MSG_CONFIG_EXISTS="設定檔存在"
    MSG_CONFIG_MISSING="設定檔不存在"
    MSG_SYNTAX_OK="logrotate -d 語法正確"
    MSG_SYNTAX_ERR="logrotate -d 回報錯誤"
    MSG_DATEEXT_OK="dateext + dateyesterday 已設定（檔名帶內容所屬日期）"
    MSG_DATEEXT_MISSING="找不到 dateext 或 dateyesterday，切出的檔案不會一天一個"
    MSG_IFEMPTY_OK="未設 notifempty（沒有日誌的當天仍會切檔）"
    MSG_IFEMPTY_BAD="仍設有 notifempty，空的日子不會切檔，日期會不連續"
    MSG_NOSIZE_OK="未設 size/maxsize（一天只會切一個檔）"
    MSG_NOSIZE_BAD="設有 size/maxsize，同一天可能切出多個檔"
    MSG_FILECOUNT="目前已輪替的檔案數（上限 ${RETENTION_DAYS}）"
    MSG_MAXFILESEC_SET="MaxFileSec 已設定（journal 一天一個檔）"
    MSG_MAXFILESEC_MISSING="找不到 MaxFileSec"
    MSG_MAXFILES_OK="SystemMaxFiles 大於保留天數"
    MSG_MAXFILES_BAD="SystemMaxFiles 未設定或不大於保留天數，實際保留天數會被檔案數上限砍短"
    MSG_SCRIPT_OK="清理腳本存在且可執行"
    MSG_SCRIPT_FAIL="清理腳本不存在或無執行權限"
    MSG_UNIT_OK="Unit 檔案存在"
    MSG_UNIT_FAIL="Unit 檔案不存在"
    MSG_TIMER_ACTIVE="計時器已啟動"
    MSG_TIMER_INACTIVE="計時器未啟動"
    MSG_NEXT_TRIGGER="下次觸發時間"
    MSG_RETENTION_SET="MaxRetentionSec 已設定"
    MSG_RETENTION_MISSING="找不到 MaxRetentionSec"
    MSG_STORAGE_SET="Storage=persistent 已設定"
    MSG_STORAGE_MISSING="找不到 Storage=persistent"
    MSG_JOURNAL_DIR_OK="持久化 journal 目錄存在"
    MSG_JOURNAL_DIR_FAIL="持久化 journal 目錄不存在"
    MSG_JOURNALD_ACTIVE="systemd-journald 運作中"
    MSG_JOURNALD_INACTIVE="systemd-journald 未運作"
    MSG_DISK_USAGE="Journal 磁碟用量"
    MSG_LR_TIMER_WARN="logrotate.timer 未啟動（Rocky 8 可能使用 cron.daily）"
    MSG_CRON_FALLBACK_OK="備援機制存在：/etc/cron.daily/logrotate"
    MSG_CRON_FALLBACK_FAIL="/etc/cron.daily/logrotate 也不存在"
    MSG_UNIT_SYNTAX_OK="systemd-analyze verify 通過（語法與相依性均正確）"
    MSG_UNIT_SYNTAX_ERR="systemd-analyze verify 回報問題"
    MSG_ALL_PASS="所有檢查項目通過。"
    MSG_FAILURES="項檢查失敗。"
else
    MSG_CONFIG_EXISTS="Config file exists"
    MSG_CONFIG_MISSING="Config file missing"
    MSG_SYNTAX_OK="logrotate -d syntax OK"
    MSG_SYNTAX_ERR="logrotate -d reported errors"
    MSG_DATEEXT_OK="dateext + dateyesterday are set (filename carries the content's own date)"
    MSG_DATEEXT_MISSING="dateext or dateyesterday missing; rotated files will not be one per day"
    MSG_IFEMPTY_OK="notifempty is absent (a file is still cut on days with no logs)"
    MSG_IFEMPTY_BAD="notifempty is still set; empty days are skipped and dates will have gaps"
    MSG_NOSIZE_OK="no size/maxsize directive (at most one file per day)"
    MSG_NOSIZE_BAD="size/maxsize is set; a single day may be split across several files"
    MSG_FILECOUNT="Rotated files currently on disk (cap ${RETENTION_DAYS})"
    MSG_MAXFILESEC_SET="MaxFileSec is set (one journal file per day)"
    MSG_MAXFILESEC_MISSING="MaxFileSec not found in config"
    MSG_MAXFILES_OK="SystemMaxFiles exceeds the retention day count"
    MSG_MAXFILES_BAD="SystemMaxFiles is unset or not greater than the retention day count; real retention will be cut short by the file-count cap"
    MSG_SCRIPT_OK="Cleanup script exists and is executable"
    MSG_SCRIPT_FAIL="Cleanup script missing or not executable"
    MSG_UNIT_OK="Unit file present"
    MSG_UNIT_FAIL="Unit file missing"
    MSG_TIMER_ACTIVE="timer is active"
    MSG_TIMER_INACTIVE="timer is not active"
    MSG_NEXT_TRIGGER="Next trigger"
    MSG_RETENTION_SET="MaxRetentionSec is set"
    MSG_RETENTION_MISSING="MaxRetentionSec not found in config"
    MSG_STORAGE_SET="Storage=persistent is set"
    MSG_STORAGE_MISSING="Storage=persistent not found in config"
    MSG_JOURNAL_DIR_OK="Persistent journal directory exists"
    MSG_JOURNAL_DIR_FAIL="Persistent journal directory missing"
    MSG_JOURNALD_ACTIVE="systemd-journald is active"
    MSG_JOURNALD_INACTIVE="systemd-journald is not active"
    MSG_DISK_USAGE="Disk usage"
    MSG_LR_TIMER_WARN="logrotate.timer is not active (Rocky 8 may use cron.daily instead)"
    MSG_CRON_FALLBACK_OK="Fallback: /etc/cron.daily/logrotate exists"
    MSG_CRON_FALLBACK_FAIL="/etc/cron.daily/logrotate also missing"
    MSG_UNIT_SYNTAX_OK="systemd-analyze verify passed (syntax and dependencies OK)"
    MSG_UNIT_SYNTAX_ERR="systemd-analyze verify reported issues"
    MSG_ALL_PASS="All checks passed."
    MSG_FAILURES="check(s) failed."
fi

FAILURES=0

# Verify the one-file-per-day policy in a logrotate config: a dated suffix so
# files are never renumbered, no notifempty so quiet days still produce a file,
# and no size trigger that would split a single day across several files.
check_daily_split() {
    local conf=$1
    # Strip comments so a commented-out directive is not mistaken for a real one.
    local body
    body=$(sed 's/#.*//' "$conf")

    if grep -qw 'dateext' <<< "$body" && grep -qw 'dateyesterday' <<< "$body"; then
        pass "$MSG_DATEEXT_OK"
    else
        fail "$MSG_DATEEXT_MISSING: $conf"
    fi

    if grep -qw 'notifempty' <<< "$body"; then
        fail "$MSG_IFEMPTY_BAD: $conf"
    else
        pass "$MSG_IFEMPTY_OK"
    fi

    if grep -qEw 'size|maxsize|minsize' <<< "$body"; then
        fail "$MSG_NOSIZE_BAD: $conf"
    else
        pass "$MSG_NOSIZE_OK"
    fi
}

# Informational only: how many rotated files a log directory currently holds.
# Counts climb toward RETENTION_DAYS over time, so this never fails the run.
report_file_count() {
    local dir=$1 pattern=$2 count
    [[ -d $dir ]] || return 0
    count=$(find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${YELLOW}i${RESET}  $MSG_FILECOUNT: $count — $dir/$pattern"
}

# ---------------------------------------------------------------------------
section "[1] Tomcat — logrotate"
TOMCAT_LR=/etc/logrotate.d/tomcat-catalina-out-180d
if [[ -f $TOMCAT_LR ]]; then
    pass "$MSG_CONFIG_EXISTS: $TOMCAT_LR"
    if logrotate -d "$TOMCAT_LR" 2>&1 | grep -qi 'error'; then
        fail "$MSG_SYNTAX_ERR"
    else
        pass "$MSG_SYNTAX_OK"
    fi
    check_daily_split "$TOMCAT_LR"
    report_file_count "$(awk 'NR==1{sub(/\/catalina\.out.*/, ""); print}' "$TOMCAT_LR")" 'catalina.out-*'
else
    fail "$MSG_CONFIG_MISSING: $TOMCAT_LR"
fi

# ---------------------------------------------------------------------------
section "[2] Tomcat — systemd cleanup timer"
CLEANUP_SCRIPT=/usr/local/sbin/cleanup-tomcat-logs
if [[ -x $CLEANUP_SCRIPT ]]; then
    pass "$MSG_SCRIPT_OK"
else
    fail "$MSG_SCRIPT_FAIL: $CLEANUP_SCRIPT"
fi

for unit in tomcat-log-cleanup.service tomcat-log-cleanup.timer; do
    if systemctl cat "$unit" &>/dev/null; then
        pass "$MSG_UNIT_OK: $unit"
    else
        fail "$MSG_UNIT_FAIL: $unit"
    fi
done

# Filter to only lines from our units; other units' warnings are irrelevant here
ANALYZE_RAW=$(systemd-analyze verify /etc/systemd/system/tomcat-log-cleanup.service /etc/systemd/system/tomcat-log-cleanup.timer 2>&1 || true)
ANALYZE_OUT=$(grep 'tomcat-log-cleanup' <<< "$ANALYZE_RAW" || true)
if [[ -z $ANALYZE_OUT ]]; then
    pass "$MSG_UNIT_SYNTAX_OK"
else
    fail "$MSG_UNIT_SYNTAX_ERR"
    while IFS= read -r line; do echo "       $line"; done <<< "$ANALYZE_OUT"
fi

TIMER_STATE=$(systemctl is-active tomcat-log-cleanup.timer 2>/dev/null || true)
if [[ $TIMER_STATE == active ]]; then
    pass "tomcat-log-cleanup.timer $MSG_TIMER_ACTIVE"
    NEXT=$(systemctl list-timers tomcat-log-cleanup.timer --no-legend 2>/dev/null | awk '{print $1, $2}')
    [[ -n $NEXT ]] && pass "$MSG_NEXT_TRIGGER: $NEXT"
else
    fail "tomcat-log-cleanup.timer $MSG_TIMER_INACTIVE (state: $TIMER_STATE)"
fi

# ---------------------------------------------------------------------------
section "[3] Nginx — logrotate"
NGINX_LR=/etc/logrotate.d/nginx
if [[ -f $NGINX_LR ]]; then
    pass "$MSG_CONFIG_EXISTS: $NGINX_LR"
    if logrotate -d "$NGINX_LR" 2>&1 | grep -qi 'error'; then
        fail "$MSG_SYNTAX_ERR"
    else
        pass "$MSG_SYNTAX_OK"
    fi
    check_daily_split "$NGINX_LR"
    report_file_count "$(awk 'NR==1{sub(/\/\*\.log.*/, ""); print}' "$NGINX_LR")" 'access.log-*'
else
    fail "$MSG_CONFIG_MISSING: $NGINX_LR"
fi

# ---------------------------------------------------------------------------
section "[4] journald retention"
JOURNALD_CONF=/etc/systemd/journald.conf.d/99-retention-180d.conf
if [[ -f $JOURNALD_CONF ]]; then
    pass "$MSG_CONFIG_EXISTS: $JOURNALD_CONF"
    grep -q 'MaxRetentionSec' "$JOURNALD_CONF" && pass "$MSG_RETENTION_SET" || fail "$MSG_RETENTION_MISSING"
    grep -q 'Storage=persistent' "$JOURNALD_CONF" && pass "$MSG_STORAGE_SET" || fail "$MSG_STORAGE_MISSING"
    grep -q 'MaxFileSec' "$JOURNALD_CONF" && pass "$MSG_MAXFILESEC_SET" || fail "$MSG_MAXFILESEC_MISSING"

    # SystemMaxFiles defaults to 100. With one journal file per day that caps
    # real retention at 100 days no matter what MaxRetentionSec says.
    MAX_FILES=$(sed -n 's/^[[:space:]]*SystemMaxFiles=\([0-9]\+\).*/\1/p' "$JOURNALD_CONF" | tail -n1)
    if [[ -n $MAX_FILES ]] && (( MAX_FILES > RETENTION_DAYS )); then
        pass "$MSG_MAXFILES_OK: SystemMaxFiles=$MAX_FILES > $RETENTION_DAYS"
    else
        fail "$MSG_MAXFILES_BAD: SystemMaxFiles=${MAX_FILES:-unset}, retention=$RETENTION_DAYS"
    fi
else
    fail "$MSG_CONFIG_MISSING: $JOURNALD_CONF"
fi

if [[ -d /var/log/journal ]]; then
    pass "$MSG_JOURNAL_DIR_OK: /var/log/journal"
else
    fail "$MSG_JOURNAL_DIR_FAIL: /var/log/journal"
fi

JOURNAL_STATE=$(systemctl is-active systemd-journald 2>/dev/null || true)
[[ $JOURNAL_STATE == active ]] && pass "$MSG_JOURNALD_ACTIVE" || fail "$MSG_JOURNALD_INACTIVE"

echo -e "\n  $MSG_DISK_USAGE: $(journalctl --disk-usage 2>/dev/null | grep -o 'Archived.*\.')"

# ---------------------------------------------------------------------------
section "[5] rsyslog — logrotate"
if [[ -f /etc/logrotate.d/rsyslog ]]; then
    SYSLOG_LR=/etc/logrotate.d/rsyslog
else
    SYSLOG_LR=/etc/logrotate.d/syslog
fi
if [[ -f $SYSLOG_LR ]]; then
    pass "$MSG_CONFIG_EXISTS: $SYSLOG_LR"
    if logrotate -d "$SYSLOG_LR" 2>&1 | grep -qi 'error'; then
        fail "$MSG_SYNTAX_ERR"
    else
        pass "$MSG_SYNTAX_OK"
    fi
    check_daily_split "$SYSLOG_LR"
    report_file_count /var/log 'messages-*'
else
    fail "$MSG_CONFIG_MISSING: $SYSLOG_LR"
fi

# ---------------------------------------------------------------------------
section "[6] logrotate timer"
LR_STATE=$(systemctl is-active logrotate.timer 2>/dev/null || true)
if [[ $LR_STATE == active ]]; then
    pass "logrotate.timer $MSG_TIMER_ACTIVE"
    NEXT=$(systemctl list-timers logrotate.timer --no-legend 2>/dev/null | awk '{print $1, $2}')
    [[ -n $NEXT ]] && pass "$MSG_NEXT_TRIGGER: $NEXT"
else
    warn "$MSG_LR_TIMER_WARN"
    [[ -f /etc/cron.daily/logrotate ]] && pass "$MSG_CRON_FALLBACK_OK" || fail "$MSG_CRON_FALLBACK_FAIL"
fi

# ---------------------------------------------------------------------------
echo ""
if (( FAILURES == 0 )); then
    echo -e "${GREEN}${BOLD}${MSG_ALL_PASS}${RESET}"
else
    echo -e "${RED}${BOLD}${FAILURES} ${MSG_FAILURES}${RESET}"
    exit 1
fi
