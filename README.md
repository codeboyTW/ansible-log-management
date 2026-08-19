# Ansible 180-day log retention

This role manages:

- Tomcat `catalina.out` with logrotate.
- Tomcat dated `.log`, `.txt`, and compressed files with a daily systemd cleanup timer.
- Nginx `*.log` files with logrotate and an Nginx USR1 reopen signal.
- Persistent systemd journal retention.
- Core rsyslog text logs on Rocky/RHEL.

Every managed log is split **one file per calendar day** and kept for **180 days**.

**Supported platforms**

| OS | Version | Notes |
|---|---|---|
| Rocky Linux | 10 | Fully supported. Same behaviour as Rocky Linux 9. |
| Rocky Linux | 9 | Fully supported. `logrotate.timer` is included in the logrotate package. |
| Rocky Linux | 8 | Supported. `logrotate.timer` is absent; logrotate runs via `cron.daily` instead. The `verify.sh` script handles this automatically. |

## 1. Retention model: one file per day

Every rotated file carries the date of the log lines inside it, so 180 days of history is 180 identifiable files rather than a stack of renumbered `.1`, `.2`, `.3` suffixes that shift meaning every night.

| Directive | Effect |
|---|---|
| `daily` | Rotate once per day, and only once |
| `dateext` + `dateformat -%Y-%m-%d` | Name rotated files `access.log-2026-08-11.gz` instead of `access.log.1` |
| `dateyesterday` | Stamp the file with the date of its contents, not the date logrotate ran |
| `rotate 180` | Keep 180 rotated files |
| `maxage 180` | Also drop anything older than 180 days, whatever the count says |
| `ifempty` | Rotate even on days that produced no log lines, so dates never skip |

Three consequences worth knowing:

**181 files on disk, not 180.** `rotate 180` keeps 180 completed days, plus the live file currently being written. That live file holds today's partial output and joins the window at the next rotation.

**The date means yesterday.** `logrotate.timer` fires shortly after midnight, so the file it produces holds the *previous* day's lines. `dateyesterday` labels it accordingly: `messages-2026-08-11.gz` contains 11 August. Without that directive the same file would be named `messages-2026-08-12.gz` and every lookup would be off by one day.

**Quiet days still produce a file.** `notifempty` is deliberately absent, so a log with no traffic still rotates and yields a near-empty `.gz` of a few dozen bytes. This keeps the date sequence unbroken, which matters when someone asks for a specific day and needs to tell "no events that day" apart from "the log is missing". Put `notifempty` back in the templates if you would rather skip empty days and accept gaps.

No `size`, `maxsize`, or `minsize` directive appears in any template. Adding one would break the model, because it lets a single day split across several files.

### 1.1 journald

journald stores binary journals rather than text, so it reaches the same policy by a different route:

| Setting | Value | Purpose |
|---|---|---|
| `MaxRetentionSec` | `180day` | Discard entries older than the retention window |
| `MaxFileSec` | `1day` | Start a new journal file at least once a day |
| `SystemMaxFiles` | `200` | Must exceed the retention day count — see below |
| `SystemMaxUse` | `20G` | Total disk ceiling across all journals |

`SystemMaxFiles` defaults to **100** in journald. With one file per day, that default alone would cap real retention at roughly 100 days no matter what `MaxRetentionSec` says, so the role raises it to 200. If you lower or raise `retention_days`, keep `journald_system_max_files` above it.

`MaxFileSec` is an upper bound, not a guarantee: journald also starts a new file whenever the current one reaches `SystemMaxFileSize` (by default one eighth of `SystemMaxUse`, so roughly 2.5G here). A busy host can therefore produce more than one journal file in a day.

### 1.2 Upgrading from an earlier version of this role

Earlier versions omitted `dateext`, so rotated files were either numbered (`access.log.1`) or — on hosts where `/etc/logrotate.conf` happens to set `dateext` globally — stamped with RHEL's default `-%Y%m%d` format. Neither matches the `-%Y-%m-%d` pattern used now, and **logrotate only counts files matching the current pattern**. Those leftovers therefore fall outside `rotate` and would sit on disk indefinitely.

After the first run, sweep them once. Preview before deleting:

```bash
sudo find /var/log/nginx /var/log -maxdepth 1 -type f \
  \( -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9]' \
     -o -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9].gz' \
     -o -name '*.[0-9]' -o -name '*.[0-9].gz' \) \
  -mtime +180 -print
```

Rerun with `-delete` in place of `-print` once the list looks right. The `-mtime +180` guard means nothing inside the retention window can be caught. The patterns match the old `-YYYYMMDD` format but not the new `-YYYY-MM-DD` one, so current files are never at risk.

Tomcat needs no manual step: `cleanup-tomcat-logs` already removes anything past the retention age.

## 2. Before running

Edit `roles/log_retention/defaults/main.yml`, especially:

- `tomcat_log_dir`
- `nginx_log_dir` — confirm the host really uses `/var/log/nginx`
- `journald_system_max_use`
- `system_text_logs`

`retention_days` is the single master knob. It drives `rotate`, `maxage`, `MaxRetentionSec`, the `find` threshold in the Tomcat cleanup script, and the `journalctl --vacuum-time` call. Changing it to `90` gives a 90-day, 90-file policy everywhere — but also raise `journald_system_max_files` if you push `retention_days` above 200.

| Variable | Default | Purpose |
|---|---|---|
| `retention_days` | `180` | Retention window, in days and in files |
| `logrotate_dateformat` | `-%Y-%m-%d` | Date suffix on rotated files. logrotate accepts only `%Y %m %d %H %M %S %V %s` |
| `journald_max_file_sec` | `1day` | How often journald starts a new journal file |
| `journald_system_max_files` | `200` | Journal file-count ceiling; must stay above `retention_days` |
| `manage_logrotate_sandbox_dropin` | `true` | Grant `logrotate.service` write access to managed log directories outside `/var` — see §5.2 |

## 3. Run

No inventory file is needed for local execution.

```bash
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

Use `-e` to selectively enable or disable components without editing any file:

```bash
# journald and rsyslog only, skip Tomcat and Nginx
ansible-playbook site.yml -e "manage_tomcat_logs=false manage_nginx_logs=false"

# Tomcat only
ansible-playbook site.yml -e "manage_nginx_logs=false manage_journald=false manage_rsyslog_logs=false"
```

The four flags and their defaults are in `roles/log_retention/defaults/main.yml`:

| Flag | Default |
|---|---|
| `manage_tomcat_logs` | `true` |
| `manage_nginx_logs` | `true` |
| `manage_journald` | `true` |
| `manage_rsyslog_logs` | `true` |

To manage remote hosts, copy `inventory.ini.example` to `inventory.ini`, fill in the target hosts, change `hosts: localhost` to `hosts: log_servers` in `site.yml`, and remove `connection: local`.

## 4. Verify

Run the bundled script for an at-a-glance pass/fail summary of all components:

```bash
sudo bash verify.sh
```

The script only ever reads. It deliberately starts, enables, and repairs nothing — a checker that fixed what it inspects could never report a genuine failure. Repairs belong to the playbook.

Besides checking that every config is present and syntactically valid, the script enforces the one-file-per-day policy: each logrotate config must carry `dateext` and `dateyesterday`, must **not** carry `notifempty`, and must **not** carry `size`/`maxsize`/`minsize`. It also fails when `SystemMaxFiles` is missing or not greater than the retention day count.

Section [7] is the one that catches silent breakage. Every other check runs logrotate by hand, which is unsandboxed and succeeds even when the scheduled service cannot write a single byte; [7] instead inspects what happened when systemd actually ran it — a failed `logrotate.service`, `Read-only file system` errors, and missing sandbox grants. See §5.2.

Those first two checks read only the **most recent** run, via the service's systemd invocation ID. A fixed problem therefore goes green on the next run rather than lingering for the length of some fixed lookback window.

The script auto-detects the locale. To force a specific language:

```bash
LANG=zh_TW.UTF-8 sudo bash verify.sh   # Traditional Chinese
LANG=en_US.UTF-8 sudo bash verify.sh   # English
```

If the role was applied with a non-default `retention_days`, tell the script:

```bash
RETENTION_DAYS=90 sudo -E bash verify.sh
```

### 4.1 Quick overview

```bash
# Check all timers are scheduled and show a next trigger time
systemctl list-timers --all | grep -E 'logrotate|tomcat-log-cleanup'

# Check all deployed logrotate configs have no syntax errors
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E 'error|warning'

# Check journal disk usage
journalctl --disk-usage
```

### 4.2 Tomcat — logrotate

```bash
cat /etc/logrotate.d/tomcat-catalina-out-180d
sudo logrotate -d /etc/logrotate.d/tomcat-catalina-out-180d
```

### 4.3 Tomcat — systemd cleanup timer

```bash
ls -l /usr/local/sbin/cleanup-tomcat-logs
systemctl status tomcat-log-cleanup.timer
systemctl list-timers tomcat-log-cleanup.timer

# Manually trigger once to confirm the script runs without errors
sudo systemctl start tomcat-log-cleanup.service
journalctl -u tomcat-log-cleanup.service -n 20
```

### 4.4 Nginx — logrotate

```bash
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx
```

### 4.5 journald retention

```bash
cat /etc/systemd/journald.conf.d/99-retention-180d.conf

# Confirm journald has loaded the new settings
systemd-analyze cat-config systemd/journald.conf \
  | grep -E 'MaxRetentionSec|MaxFileSec|SystemMaxFiles|MaxUse|Storage'

# Confirm journal directory is persistent, and count journal files
ls /var/log/journal/
journalctl --header | grep -c 'File path'
```

### 4.6 rsyslog — logrotate

```bash
cat /etc/logrotate.d/rsyslog
sudo logrotate -d /etc/logrotate.d/rsyslog
```

`list-timers` output showing a `LAST` timestamp and a `NEXT` time tomorrow means the timers are active. No `error` output from `logrotate -d` means all config files are syntactically valid.

### 4.7 Confirming the daily split

The split only becomes visible after the first rotation. To see it immediately on a test host, force one rotation and check that the filename carries **yesterday's** date:

```bash
sudo logrotate -f /etc/logrotate.d/nginx
ls -l /var/log/nginx/
```

Thereafter the file count climbs by one per day and settles at 180:

```bash
ls -1 /var/log/nginx/access.log-* | wc -l
ls -1 /var/log/messages-* | wc -l
```

Note that `dateext` makes logrotate skip a rotation whose target filename already exists, so running `logrotate -f` twice in one day rotates only the first time. The daily timer never hits this.

## 5. Why systemd timer for Tomcat logs

Tomcat produces two fundamentally different types of log files that require different tools:

**`catalina.out`** is a single continuously-written file. Logrotate handles it by renaming with a date suffix, compressing, and pruning old rotations — the standard logrotate workflow.

**Dated log files** (e.g. `catalina.2026-08-01.log`, `localhost.2026-08-01.log`) are created by Tomcat itself via `java.util.logging`. Tomcat opens a new file each day automatically and never touches the old ones again — they are already one file per day, so they need deletion, not rotation. Logrotate cannot manage them because it has no mechanism to match a glob pattern against file age and delete matches in bulk.

The `cleanup-tomcat-logs` script uses `find -mmin` to delete any `.log`, `.txt`, or compressed file older than `retention_days`, excluding `catalina.out` itself and logrotate's own `catalina.out-*` output so that each file has exactly one owner. The systemd timer runs this script daily and provides `Persistent=true` to catch up if the host was offline, along with `ConditionPathIsDirectory` to skip safely when the log directory does not exist.

| Tool | Target | Mechanism |
|---|---|---|
| logrotate | `catalina.out` | rename with date suffix → compress → keep 180 |
| systemd timer + find | `catalina.*.log` and other dated files | delete by modification age |

Because `find` measures *modification* time and the timer runs at 02:35 rather than midnight, a Tomcat dated file can outlive the window by up to a day. Seeing a 181st file occasionally is expected, not a fault.

### 5.1 Cleanup timer schedule

The timer (`tomcat-log-cleanup.timer`) fires at **02:35** each day with a random jitter of up to 15 minutes. Key settings:

| Setting | Value | Purpose |
|---|---|---|
| `OnCalendar` | `*-*-* 02:35:00` | Runs after logrotate (midnight) so rotated files are already in place |
| `Persistent=true` | — | Re-runs on next boot if the host was offline at trigger time |
| `RandomizedDelaySec=15m` | — | Spreads execution across a fleet to avoid simultaneous disk I/O |

Recommended daily order to avoid I/O contention:

```
logrotate  →  tomcat cleanup  →  backups
(00:00)       (02:35)            (04:00+)
```

Adjust `OnCalendar` if other scheduled jobs on the host conflict with this window.

### 5.2 Log directories outside /var

`logrotate.service` on Rocky/RHEL runs inside a systemd sandbox that mounts `/usr` read-only. A Tomcat installed at `/usr/local/tomcat` therefore cannot have its `catalina.out` rotated by the scheduled service:

```
logrotate[3271029]: error: error opening /usr/local/tomcat/logs/catalina.out: Read-only file system
systemd[1]: logrotate.service: Failed with result 'exit-code'.
```

This failure is unusually easy to miss. `logrotate -d` and `logrotate -f` run from a root shell are **not** sandboxed, so they succeed and report nothing wrong — the error appears only in `journalctl -u logrotate.service`. Meanwhile logrotate still rotates every other log correctly and merely exits non-zero at the end, so nothing else looks broken. Rotation can stay dead for weeks with no visible symptom beyond a log file that never gets smaller.

The role handles this automatically. Any managed log directory outside `/var` gets a drop-in at `/etc/systemd/system/logrotate.service.d/10-log-retention-paths.conf`:

```
[Service]
ReadWritePaths=-/usr/local/tomcat/logs
```

`ReadWritePaths=` re-grants write access for that path only. It appends to whatever the vendor unit already lists rather than replacing it, and the leading `-` keeps the unit startable when the directory is absent. A drop-in under `/etc/systemd/system/` also survives package upgrades, unlike an edited vendor unit.

Deploying the grant is not the same as proving it works, so whenever the drop-in changes the role finishes by running `systemctl start logrotate.service` once. That is an ordinary run, not `logrotate -f`: it rotates only what is genuinely due, and a successful run clears any leftover failed state on the unit. Most importantly, a grant that is still wrong fails the play right there, rather than leaving the breakage to surface at some later midnight.

Set `manage_logrotate_sandbox_dropin: false` to opt out — for instance when the site manages logrotate hardening centrally.

**The better long-term fix is to keep logs under `/var/log`**, which is what the FHS intends and what the sandbox is designed around. Move Tomcat's logs to `/var/log/tomcat` and point `tomcat_log_dir` there, and the drop-in becomes unnecessary — the role deploys nothing, because no managed directory falls outside `/var`. The files also get the correct `var_log_t` SELinux context instead of `usr_t`. The trade-off is that moving them requires stopping Tomcat, which the drop-in does not.

## 6. Scope warning

"All Linux system logs" are not controlled by one subsystem. This role covers
journald and the listed core rsyslog files. Auditd (`/var/log/audit/audit.log`),
DNF logs, databases, containers, and application-specific logs may have their
own retention mechanisms and should be managed separately.
