#!/usr/bin/env bash
# Run as root (or with sudo) to allow logrotate -d validation.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail() { echo -e "  ${RED}✗${RESET}  $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}!${RESET}  $*"; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

# Detect locale: use Traditional Chinese when LANG/LC_ALL is zh_TW or zh_HK
_locale="${LC_ALL:-${LANG:-}}"
if [[ $_locale == zh_TW* || $_locale == zh_HK* ]]; then
    MSG_CONFIG_EXISTS="設定檔存在"
    MSG_CONFIG_MISSING="設定檔不存在"
    MSG_SYNTAX_OK="logrotate -d 語法正確"
    MSG_SYNTAX_ERR="logrotate -d 回報錯誤"
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
