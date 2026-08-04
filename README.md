# Ansible 180-day log retention

This role manages:

- Tomcat `catalina.out` with logrotate.
- Tomcat dated `.log`, `.txt`, and compressed files with a daily systemd cleanup timer.
- Nginx `*.log` files with logrotate and an Nginx USR1 reopen signal.
- Persistent systemd journal retention.
- Core rsyslog text logs on Rocky/RHEL.

**Supported platforms**

| OS | Version | Notes |
|---|---|---|
| Rocky Linux | 10 | Fully supported. Same behaviour as Rocky Linux 9. |
| Rocky Linux | 9 | Fully supported. `logrotate.timer` is included in the logrotate package. |
| Rocky Linux | 8 | Supported. `logrotate.timer` is absent; logrotate runs via `cron.daily` instead. The `verify.sh` script handles this automatically. |

## 1. Before running

Edit `roles/log_retention/defaults/main.yml`, especially:

- `tomcat_log_dir`
- `nginx_log_dir`
- `journald_system_max_use`
- `system_text_logs`

The requested Nginx path is `/var/logs/nginx`. If the host actually uses
`/var/log/nginx`, change the variable before running.

## 2. Run

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

## 3. Verify

Run the bundled script for an at-a-glance pass/fail summary of all components:

```bash
sudo bash verify.sh
```

The script auto-detects the locale. To force a specific language:

```bash
LANG=zh_TW.UTF-8 sudo bash verify.sh   # Traditional Chinese
LANG=en_US.UTF-8 sudo bash verify.sh   # English
```

### 3.1 Quick overview

```bash
# Check all timers are scheduled and show a next trigger time
systemctl list-timers --all | grep -E 'logrotate|tomcat-log-cleanup'

# Check all deployed logrotate configs have no syntax errors
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -E 'error|warning'

# Check journal disk usage
journalctl --disk-usage
```

### 3.2 Tomcat — logrotate

```bash
cat /etc/logrotate.d/tomcat-catalina-out-180d
sudo logrotate -d /etc/logrotate.d/tomcat-catalina-out-180d
```

### 3.3 Tomcat — systemd cleanup timer

```bash
ls -l /usr/local/sbin/cleanup-tomcat-logs
systemctl status tomcat-log-cleanup.timer
systemctl list-timers tomcat-log-cleanup.timer

# Manually trigger once to confirm the script runs without errors
sudo systemctl start tomcat-log-cleanup.service
journalctl -u tomcat-log-cleanup.service -n 20
```

### 3.4 Nginx — logrotate

```bash
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx
```

### 3.5 journald retention

```bash
cat /etc/systemd/journald.conf.d/99-retention-180d.conf

# Confirm journald has loaded the new settings
systemd-analyze cat-config systemd/journald.conf | grep -E 'Retention|MaxUse|Storage'

# Confirm journal directory is persistent
ls /var/log/journal/
```

### 3.6 rsyslog — logrotate

```bash
cat /etc/logrotate.d/rsyslog
sudo logrotate -d /etc/logrotate.d/rsyslog
```

`list-timers` output showing a `LAST` timestamp and a `NEXT` time tomorrow means the timers are active. No `error` output from `logrotate -d` means all config files are syntactically valid.

## 4. Why systemd timer for Tomcat logs

Tomcat produces two fundamentally different types of log files that require different tools:

**`catalina.out`** is a single continuously-written file. Logrotate handles it by renaming, compressing, and pruning old rotations — the standard logrotate workflow.

**Dated log files** (e.g. `catalina.2026-08-01.log`, `localhost.2026-08-01.log`) are created by Tomcat itself via `java.util.logging`. Tomcat opens a new file each day automatically and never touches the old ones again. Logrotate cannot manage these because it has no mechanism to match a glob pattern against file age and delete matches in bulk.

The `cleanup-tomcat-logs` script uses `find -mmin` to delete any `.log`, `.txt`, or compressed file older than `retention_days` (excluding `catalina.out` itself). The systemd timer runs this script daily and provides `Persistent=true` to catch up if the host was offline, along with `ConditionPathIsDirectory` to skip safely when the log directory does not exist.

| Tool | Target | Mechanism |
|---|---|---|
| logrotate | `catalina.out` | rename → compress → rotate count |
| systemd timer + find | `catalina.*.log` and other dated files | delete by modification age |

### 4.1 Cleanup timer schedule

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

## 5. Scope warning

"All Linux system logs" are not controlled by one subsystem. This role covers
journald and the listed core rsyslog files. Auditd (`/var/log/audit/audit.log`),
DNF logs, databases, containers, and application-specific logs may have their
own retention mechanisms and should be managed separately.
