# Ansible 180 天日誌保留

此 role 管理以下項目：

- 以 logrotate 管理 Tomcat 的 `catalina.out`。
- 以每日 systemd 清理計時器管理 Tomcat 日期格式的 `.log`、`.txt` 及壓縮檔。
- 以 logrotate 搭配 Nginx USR1 重新開啟訊號管理 Nginx `*.log` 檔案。
- 持久化 systemd journal 的保留設定。
- Rocky/RHEL 上核心 rsyslog 純文字日誌。

**支援的作業系統**

| 作業系統 | 版本 | 說明 |
|---|---|---|
| Rocky Linux | 10 | 完整支援。行為與 Rocky Linux 9 相同。 |
| Rocky Linux | 9 | 完整支援。logrotate 套件已內含 `logrotate.timer`。 |
| Rocky Linux | 8 | 支援。logrotate 套件不含 `logrotate.timer`，改由 `cron.daily` 執行。`verify.sh` 已自動處理此差異。 |

## 1. 執行前

請編輯 `roles/log_retention/defaults/main.yml`，特別注意以下變數：

- `tomcat_log_dir`
- `nginx_log_dir`
- `journald_system_max_use`
- `system_text_logs`

Nginx 路徑預設為 `/var/logs/nginx`。若主機實際使用的是 `/var/log/nginx`，請在執行前修改此變數。

## 2. 執行方式

本機執行不需要 inventory 檔案。

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

使用 `-e` 可很選擇性起用或停用各元件，不需要修改任何檔案：

```bash
# 只跑 journald 和 rsyslog，跳過 Tomcat 和 Nginx
ansible-playbook site.yml -e "manage_tomcat_logs=false manage_nginx_logs=false"

# 只跑 Tomcat
ansible-playbook site.yml -e "manage_nginx_logs=false manage_journald=false manage_rsyslog_logs=false"
```

四個控制旗標及預設値在 `roles/log_retention/defaults/main.yml`：

| 旗標 | 預設 |
|---|---|
| `manage_tomcat_logs` | `true` |
| `manage_nginx_logs` | `true` |
| `manage_journald` | `true` |
| `manage_rsyslog_logs` | `true` |

若要管理遠端主機，請將 `inventory.ini.example` 複製為 `inventory.ini` 並填入目標主機，同時將 `site.yml` 的 `hosts: localhost` 改為 `hosts: log_servers` 並移除 `connection: local`。

## 3. 驗證

執行內附腳本，一次檢視所有元件的通過／失敗結果：

```bash
sudo bash verify.sh
```

腳本會自動偵測語系，也可手動指定：

```bash
LANG=zh_TW.UTF-8 sudo bash verify.sh   # 繁體中文
LANG=en_US.UTF-8 sudo bash verify.sh   # 英文
```

### 3.1 快速總覽

```bash
# 確認所有計時器已排程並顯示下次觸發時間
systemctl list-timers --all | grep -E 'logrotate|tomcat-log-cleanup'

# 確認所有 logrotate 設定檔語法正確
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E 'error|warning'

# 確認 journal 磁碟用量
journalctl --disk-usage
```

### 3.2 Tomcat — logrotate

```bash
cat /etc/logrotate.d/tomcat-catalina-out-180d
sudo logrotate -d /etc/logrotate.d/tomcat-catalina-out-180d
```

### 3.3 Tomcat — systemd 清理計時器

```bash
ls -l /usr/local/sbin/cleanup-tomcat-logs
systemctl status tomcat-log-cleanup.timer
systemctl list-timers tomcat-log-cleanup.timer

# 手動觸發一次確認腳本執行無錯誤
sudo systemctl start tomcat-log-cleanup.service
journalctl -u tomcat-log-cleanup.service -n 20
```

### 3.4 Nginx — logrotate

```bash
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx
```

### 3.5 journald 保留設定

```bash
cat /etc/systemd/journald.conf.d/99-retention-180d.conf

# 確認 journald 已載入新設定
systemd-analyze cat-config systemd/journald.conf | grep -E 'Retention|MaxUse|Storage'

# 確認 journal 目錄為持久化模式
ls /var/log/journal/
```

### 3.6 rsyslog — logrotate

```bash
cat /etc/logrotate.d/rsyslog
sudo logrotate -d /etc/logrotate.d/rsyslog
```

`list-timers` 輸出中 `LAST` 有時間戳且 `NEXT` 顯示明天，代表計時器正常運作。`logrotate -d` 無 `error` 輸出，代表所有設定檔語法正確。

## 4. 為何 Tomcat 日誌需要 systemd 計時器

Tomcat 產生兩種性質完全不同的日誌檔案，必須用不同的工具處理：

**`catalina.out`** 是一個持續被寫入的單一檔案。logrotate 透過重新命名、壓縮、刪除舊份的標準流程來管理它。

**日期格式日誌**（例如 `catalina.2026-08-01.log`、`localhost.2026-08-01.log`）由 Tomcat 本身透過 `java.util.logging` 建立。Tomcat 每天自動開啟新檔，舊檔從此不再寫入。logrotate 無法管理這類檔案，因為它沒有機制能對符合 glob 樣式且超過指定年齡的檔案進行批次刪除。

`cleanup-tomcat-logs` 腳本使用 `find -mmin` 刪除所有超過 `retention_days` 天未修改的 `.log`、`.txt` 及壓縮檔（排除 `catalina.out` 本身）。systemd 計時器每日觸發此腳本，並透過 `Persistent=true` 補跑機器離線期間錯過的執行，以及 `ConditionPathIsDirectory` 在日誌目錄不存在時自動略過。

| 工具 | 管理對象 | 機制 |
|---|---|---|
| logrotate | `catalina.out` | rename → compress → rotate count |
| systemd timer + find | `catalina.*.log` 等日期格式檔案 | 依修改時間刪除超齡檔案 |

### 4.1 清理計時器排程

計時器（`tomcat-log-cleanup.timer`）每天 **02:35** 觸發，並加上最多 15 分鐘的隨機延遲。主要設定說明：

| 設定 | 值 | 用途 |
|---|---|---|
| `OnCalendar` | `*-*-* 02:35:00` | 在 logrotate（午夜）之後執行，確保輪替檔案已就位 |
| `Persistent=true` | — | 若主機在觸發時間關機，開機後補跑一次 |
| `RandomizedDelaySec=15m` | — | 多台主機分散執行時間，避免同時搶佔磁碟 I/O |

建議的每日排程順序，避免 I/O 衝突：

```
logrotate  →  tomcat cleanup  →  備份
(00:00)       (02:35)            (04:00+)
```

若主機有其他排程與此時段衝突，請調整 `OnCalendar` 的時間。

## 5. 範圍說明

「所有 Linux 系統日誌」並非由單一子系統控制。此 role 涵蓋 journald 及上述核心 rsyslog 檔案。Auditd（`/var/log/audit/audit.log`）、DNF 日誌、資料庫、容器及各應用程式專屬的日誌可能有各自的保留機制，應另行管理。
