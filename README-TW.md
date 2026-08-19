# Ansible 180 天日誌保留

此 role 管理以下項目：

- 以 logrotate 管理 Tomcat 的 `catalina.out`。
- 以每日 systemd 清理計時器管理 Tomcat 日期格式的 `.log`、`.txt` 及壓縮檔。
- 以 logrotate 搭配 Nginx USR1 重新開啟訊號管理 Nginx `*.log` 檔案。
- 持久化 systemd journal 的保留設定。
- Rocky/RHEL 上核心 rsyslog 純文字日誌。

所有納管的日誌一律**一天切一個檔**，並**保留 180 天**。

**支援的作業系統**

| 作業系統 | 版本 | 說明 |
|---|---|---|
| Rocky Linux | 10 | 完整支援。行為與 Rocky Linux 9 相同。 |
| Rocky Linux | 9 | 完整支援。logrotate 套件已內含 `logrotate.timer`。 |
| Rocky Linux | 8 | 支援。logrotate 套件不含 `logrotate.timer`，改由 `cron.daily` 執行。`verify.sh` 已自動處理此差異。 |

## 1. 保留模型：一天一個檔

每個輪替出來的檔案，檔名都帶著「檔案內容所屬那一天」的日期，因此 180 天的歷史就是 180 個可辨識的檔案，而不是每晚重新編號、意義會整批位移的 `.1`、`.2`、`.3`。

| 指令 | 作用 |
|---|---|
| `daily` | 每天輪替一次，且只有一次 |
| `dateext` + `dateformat -%Y-%m-%d` | 輪替後命名為 `access.log-2026-08-11.gz`，而非 `access.log.1` |
| `dateyesterday` | 檔名日期代表內容所屬的日期，而非 logrotate 執行的日期 |
| `rotate 180` | 保留 180 個輪替檔 |
| `maxage 180` | 同時清掉超過 180 天的檔案，不論數量是否已達上限 |
| `ifempty` | 即使當天沒有任何日誌也照樣輪替，日期不會跳號 |

有三個衍生行為需要知道：

**磁碟上是 181 個檔，不是 180 個。** `rotate 180` 保留的是 180 個「已完成的日子」，再加上當下正在寫入的即時檔案。該即時檔裝的是今天尚未結束的內容，會在下一次輪替時加入這個 180 天視窗。

**檔名的日期代表昨天。** `logrotate.timer` 在午夜過後不久觸發，因此它切出來的檔案裝的是**前一天**的內容。`dateyesterday` 讓命名與內容一致：`messages-2026-08-11.gz` 裝的就是 8 月 11 日的紀錄。若沒有這個指令，同一個檔案會被命名為 `messages-2026-08-12.gz`，之後每次查日誌都會差一天。

**沒有日誌的日子仍會產生檔案。** 這裡是刻意不設 `notifempty`，所以當天毫無流量的日誌仍會輪替，產生一個只有幾十個 byte 的近乎空白 `.gz`。這樣日期序列不會中斷 —— 當有人要調閱某一天的紀錄時，才能分辨「那天沒有事件」與「日誌檔不見了」這兩種完全不同的狀況。若你寧可跳過空白日、接受序列有缺口，把 `notifempty` 加回 template 即可。

所有 template 都沒有 `size`、`maxsize`、`minsize` 指令。加上去會破壞這個模型，因為那會讓同一天的內容被拆成好幾個檔案。

### 1.1 journald

journald 儲存的是二進位 journal 而非純文字，因此以不同的方式達成同一套政策：

| 設定 | 值 | 用途 |
|---|---|---|
| `MaxRetentionSec` | `180day` | 丟棄超過保留期限的紀錄 |
| `MaxFileSec` | `1day` | 至少每天開一個新的 journal 檔 |
| `SystemMaxFiles` | `200` | 必須大於保留天數 —— 說明見下 |
| `SystemMaxUse` | `20G` | 所有 journal 加總的磁碟用量上限 |

journald 的 `SystemMaxFiles` 預設值是 **100**。在一天一個檔的前提下，光是這個預設值就會讓實際保留期被砍到大約 100 天，無論 `MaxRetentionSec` 設多少都一樣，所以此 role 將它提高到 200。若你調整 `retention_days`，記得讓 `journald_system_max_files` 保持在它之上。

`MaxFileSec` 是上限而非保證：當單一 journal 檔達到 `SystemMaxFileSize`（預設為 `SystemMaxUse` 的八分之一，此處約 2.5G）時，journald 也會開新檔。因此日誌量大的主機一天可能產生不只一個 journal 檔。

### 1.2 從舊版 role 升級

舊版沒有設 `dateext`，因此輪替檔要嘛是數字編號（`access.log.1`），要嘛 —— 在 `/etc/logrotate.conf` 剛好有全域設定 `dateext` 的主機上 —— 使用 RHEL 預設的 `-%Y%m%d` 格式。這兩種都不符合現在使用的 `-%Y-%m-%d` 樣式，而 **logrotate 只會計算符合當前樣式的檔案**。那些殘留檔因此落在 `rotate` 的管轄之外，會永遠留在磁碟上。

第一次套用後清理一次即可。刪除前先預覽：

```bash
sudo find /var/log/nginx /var/log -maxdepth 1 -type f \
  \( -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9]' \
     -o -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9].gz' \
     -o -name '*.[0-9]' -o -name '*.[0-9].gz' \) \
  -mtime +180 -print
```

確認清單無誤後，把 `-print` 換成 `-delete` 再跑一次。`-mtime +180` 這道保護確保保留期內的檔案不可能被掃到；而上述樣式只比對舊的 `-YYYYMMDD` 格式，不會比對到新的 `-YYYY-MM-DD` 格式，因此現行檔案絕不會有風險。

Tomcat 端不需要手動處理，`cleanup-tomcat-logs` 本來就會刪除超過保留期限的檔案。

## 2. 執行前

請編輯 `roles/log_retention/defaults/main.yml`，特別注意以下變數：

- `tomcat_log_dir`
- `nginx_log_dir` —— 請確認主機實際使用的是否為 `/var/log/nginx`
- `journald_system_max_use`
- `system_text_logs`

`retention_days` 是唯一的主控開關，它同時驅動 `rotate`、`maxage`、`MaxRetentionSec`、Tomcat 清理腳本中的 `find` 門檻，以及 `journalctl --vacuum-time`。改成 `90` 就是全面 90 天、90 個檔的政策 —— 但若你把 `retention_days` 調到 200 以上，記得一併提高 `journald_system_max_files`。

| 變數 | 預設值 | 用途 |
|---|---|---|
| `retention_days` | `180` | 保留期，同時是天數與檔案數 |
| `logrotate_dateformat` | `-%Y-%m-%d` | 輪替檔的日期後綴。logrotate 只接受 `%Y %m %d %H %M %S %V %s` |
| `journald_max_file_sec` | `1day` | journald 多久開一個新的 journal 檔 |
| `journald_system_max_files` | `200` | journal 檔案數上限，必須大於 `retention_days` |
| `manage_logrotate_sandbox_dropin` | `true` | 為 `/var` 之外的納管日誌目錄，授予 `logrotate.service` 寫入權限 —— 見 §5.2 |

## 3. 執行方式

本機執行不需要 inventory 檔案。

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

使用 `-e` 可選擇性起用或停用各元件，不需要修改任何檔案：

```bash
# 只跑 journald 和 rsyslog，跳過 Tomcat 和 Nginx
ansible-playbook site.yml -e "manage_tomcat_logs=false manage_nginx_logs=false"

# 只跑 Tomcat
ansible-playbook site.yml -e "manage_nginx_logs=false manage_journald=false manage_rsyslog_logs=false"
```

四個控制旗標及預設值在 `roles/log_retention/defaults/main.yml`：

| 旗標 | 預設 |
|---|---|
| `manage_tomcat_logs` | `true` |
| `manage_nginx_logs` | `true` |
| `manage_journald` | `true` |
| `manage_rsyslog_logs` | `true` |

若要管理遠端主機，請將 `inventory.ini.example` 複製為 `inventory.ini` 並填入目標主機，同時將 `site.yml` 的 `hosts: localhost` 改為 `hosts: log_servers` 並移除 `connection: local`。

## 4. 驗證

執行內附腳本，一次檢視所有元件的通過／失敗結果：

```bash
sudo bash verify.sh
```

此腳本只讀不寫，刻意不啟動、不啟用、不修復任何東西 —— 一個會順手修好受檢對象的檢查程式，永遠回報不出真正的失敗。修復是 playbook 的職責。

除了檢查各設定檔是否存在且語法正確之外，腳本也會強制檢驗一天一檔的政策：每個 logrotate 設定檔必須含有 `dateext` 與 `dateyesterday`，**不得**含有 `notifempty`，也**不得**含有 `size`／`maxsize`／`minsize`。若 `SystemMaxFiles` 未設定或未大於保留天數，同樣會判定失敗。

第 [7] 區塊是專門用來抓「無聲失效」的。其他所有檢查都是手動執行 logrotate —— 手動執行沒有沙箱，就算排程服務一個 byte 都寫不進去也照樣會成功；[7] 改為檢視 systemd 實際執行時發生了什麼：`logrotate.service` 是否處於 failed、有沒有 `Read-only file system` 錯誤、以及沙箱授權是否缺漏。詳見 §5.2。

前兩項只讀取**最近一次**執行的紀錄（透過該服務的 systemd invocation ID）。因此問題修好後下一次執行就會轉綠，不會像固定回溯區間那樣，修好了還要繼續紅上一段時間。

腳本會自動偵測語系，也可手動指定：

```bash
LANG=zh_TW.UTF-8 sudo bash verify.sh   # 繁體中文
LANG=en_US.UTF-8 sudo bash verify.sh   # 英文
```

若套用 role 時使用了非預設的 `retention_days`，請一併告知腳本：

```bash
RETENTION_DAYS=90 sudo -E bash verify.sh
```

### 4.1 快速總覽

```bash
# 確認所有計時器已排程並顯示下次觸發時間
systemctl list-timers --all | grep -E 'logrotate|tomcat-log-cleanup'

# 確認所有 logrotate 設定檔語法正確
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E 'error|warning'

# 確認 journal 磁碟用量
journalctl --disk-usage
```

### 4.2 Tomcat — logrotate

```bash
cat /etc/logrotate.d/tomcat-catalina-out-180d
sudo logrotate -d /etc/logrotate.d/tomcat-catalina-out-180d
```

### 4.3 Tomcat — systemd 清理計時器

```bash
ls -l /usr/local/sbin/cleanup-tomcat-logs
systemctl status tomcat-log-cleanup.timer
systemctl list-timers tomcat-log-cleanup.timer

# 手動觸發一次確認腳本執行無錯誤
sudo systemctl start tomcat-log-cleanup.service
journalctl -u tomcat-log-cleanup.service -n 20
```

### 4.4 Nginx — logrotate

```bash
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx
```

### 4.5 journald 保留設定

```bash
cat /etc/systemd/journald.conf.d/99-retention-180d.conf

# 確認 journald 已載入新設定
systemd-analyze cat-config systemd/journald.conf \
  | grep -E 'MaxRetentionSec|MaxFileSec|SystemMaxFiles|MaxUse|Storage'

# 確認 journal 目錄為持久化模式，並計算 journal 檔案數
ls /var/log/journal/
journalctl --header | grep -c 'File path'
```

### 4.6 rsyslog — logrotate

```bash
cat /etc/logrotate.d/rsyslog
sudo logrotate -d /etc/logrotate.d/rsyslog
```

`list-timers` 輸出中 `LAST` 有時間戳且 `NEXT` 顯示明天，代表計時器正常運作。`logrotate -d` 無 `error` 輸出，代表所有設定檔語法正確。

### 4.7 確認每日切檔

切檔效果要等到第一次輪替之後才看得到。若想在測試機上立刻確認，可強制輪替一次，並檢查檔名帶的是**昨天**的日期：

```bash
sudo logrotate -f /etc/logrotate.d/nginx
ls -l /var/log/nginx/
```

之後檔案數每天增加一個，最終穩定在 180：

```bash
ls -1 /var/log/nginx/access.log-* | wc -l
ls -1 /var/log/messages-* | wc -l
```

請注意 `dateext` 的既有行為：若目標檔名已存在，logrotate 會略過該次輪替，因此同一天內跑兩次 `logrotate -f` 只有第一次會生效。每日計時器不會遇到這個狀況。

## 5. 為何 Tomcat 日誌需要 systemd 計時器

Tomcat 產生兩種性質完全不同的日誌檔案，必須用不同的工具處理：

**`catalina.out`** 是一個持續被寫入的單一檔案。logrotate 透過加上日期後綴重新命名、壓縮、刪除舊份的標準流程來管理它。

**日期格式日誌**（例如 `catalina.2026-08-01.log`、`localhost.2026-08-01.log`）由 Tomcat 本身透過 `java.util.logging` 建立。Tomcat 每天自動開啟新檔，舊檔從此不再寫入 —— 它們本來就已經是一天一個檔，需要的是刪除而不是輪替。logrotate 無法管理這類檔案，因為它沒有機制能對符合 glob 樣式且超過指定年齡的檔案進行批次刪除。

`cleanup-tomcat-logs` 腳本使用 `find -mmin` 刪除所有超過 `retention_days` 天未修改的 `.log`、`.txt` 及壓縮檔，並排除 `catalina.out` 本身以及 logrotate 自己產出的 `catalina.out-*`，讓每個檔案都只有單一機制負責。systemd 計時器每日觸發此腳本，並透過 `Persistent=true` 補跑機器離線期間錯過的執行，以及 `ConditionPathIsDirectory` 在日誌目錄不存在時自動略過。

| 工具 | 管理對象 | 機制 |
|---|---|---|
| logrotate | `catalina.out` | 加日期後綴重新命名 → 壓縮 → 保留 180 份 |
| systemd timer + find | `catalina.*.log` 等日期格式檔案 | 依修改時間刪除超齡檔案 |

由於 `find` 判斷的是**修改**時間，而計時器是在 02:35 而非午夜執行，Tomcat 的日期格式檔案最多可能多存活不到一天。偶爾看到第 181 個檔案屬於預期行為，不是缺陷。

### 5.1 清理計時器排程

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

### 5.2 位於 /var 之外的日誌目錄

Rocky/RHEL 的 `logrotate.service` 執行在 systemd 沙箱裡，該沙箱會把 `/usr` 掛載為唯讀。因此裝在 `/usr/local/tomcat` 的 Tomcat，它的 `catalina.out` 無法被排程服務輪替：

```
logrotate[3271029]: error: error opening /usr/local/tomcat/logs/catalina.out: Read-only file system
systemd[1]: logrotate.service: Failed with result 'exit-code'.
```

這個失敗特別容易被忽略。在 root shell 手動執行的 `logrotate -d` 與 `logrotate -f` **不會**進入沙箱，所以它們會成功、也不會回報任何異常 —— 錯誤只出現在 `journalctl -u logrotate.service`。與此同時，logrotate 仍會正確輪替其他所有日誌，只是最後回傳非零離開碼，因此表面上看不出任何問題。輪替可以就這樣死掉好幾週，唯一的徵兆是某個日誌檔永遠不會變小。

此 role 會自動處理。任何位於 `/var` 之外的納管日誌目錄，都會取得一份 drop-in，路徑為 `/etc/systemd/system/logrotate.service.d/10-log-retention-paths.conf`：

```
[Service]
ReadWritePaths=-/usr/local/tomcat/logs
```

`ReadWritePaths=` 只針對該路徑重新授予寫入權限。它是**附加**在原本 unit 已列出的項目之後，而非取代；開頭的 `-` 則讓目錄不存在時 unit 仍能正常啟動。放在 `/etc/systemd/system/` 底下的 drop-in 也不會像直接改原廠 unit 那樣，在套件升級時被覆蓋。

「部署了授權」不等於「授權真的有效」，因此只要 drop-in 有變動，role 最後會執行一次 `systemctl start logrotate.service`。這是一般執行而非 `logrotate -f`：只輪替真正到期的項目，而執行成功也會順帶清掉 unit 上殘留的 failed 狀態。最重要的是，若授權仍然有問題，playbook 會當場失敗，而不是把問題留到某天半夜才浮現。

若要停用（例如站台自行統一管理 logrotate 的強化設定），將 `manage_logrotate_sandbox_dropin` 設為 `false` 即可。

**長期而言更好的做法是把日誌放在 `/var/log` 底下** —— 這才是 FHS 的規範，也是沙箱設計時所預期的位置。把 Tomcat 的日誌搬到 `/var/log/tomcat` 並將 `tomcat_log_dir` 指過去之後，drop-in 就不再需要：沒有任何納管目錄落在 `/var` 之外，role 就不會部署它。檔案也會取得正確的 `var_log_t` SELinux context，而不是 `usr_t`。代價是搬遷必須停用 Tomcat，而 drop-in 不需要。

## 6. 範圍說明

「所有 Linux 系統日誌」並非由單一子系統控制。此 role 涵蓋 journald 及上述核心 rsyslog 檔案。Auditd（`/var/log/audit/audit.log`）、DNF 日誌、資料庫、容器及各應用程式專屬的日誌可能有各自的保留機制，應另行管理。
