# PostgreSQL Backup Script

Automates daily PostgreSQL backups stored locally and uploaded to DigitalOcean Spaces.

---

## Features

- Daily backups only (one per day — replaces existing backup for the same day)
- Keeps last 3 days of local backups
- Uploads each backup to DigitalOcean Spaces
- Supports Docker container mode or native pg_dump mode

---

## Requirements

- `aws` CLI (used for DO Spaces S3-compatible API — auto-installed if missing)
- `docker` (if using container mode)
- `pg_dump` (if using native mode)

---

## Configuration Files

Create these files on the server before running the script.

**`/etc/backup/do.conf`**
```bash
DO_ACCESS_KEY='your_access_key'
DO_SECRET_KEY='your_secret_key'
DO_SPACE='your_space_name'
DO_REGION='your_region'        # e.g. nyc3, sgp1, blr1
DO_PATH='backups'
```

**`/etc/backup/pg.conf`** *(only needed for native mode)*
```bash
PG_USER='your_db_user'
PG_PASSWORD='your_db_password'
PG_DATABASE='your_db_name'
PG_HOST='your_db_host'
```

Set secure permissions:
```bash
sudo chmod 600 /etc/backup/do.conf
sudo chmod 600 /etc/backup/pg.conf
```

---

## Usage

### Docker container mode
```bash
./backup.sh -c <container_name>
```

### Native mode (pg_dump on host)
```bash
./backup.sh -n
```
Credentials are loaded from `/etc/backup/pg.conf`. Or pass them as arguments:
```bash
./backup.sh -n --pg-host localhost --pg-user mmuser --pg-password secret --pg-database mattermost
```

---

## All Options

| Flag | Description |
|------|-------------|
| `-c, --container` | Docker container name |
| `-n, --native` | Use native pg_dump |
| `--pg-host` | PostgreSQL host |
| `--pg-user` | PostgreSQL username |
| `--pg-password` | PostgreSQL password |
| `--pg-database` | PostgreSQL database name |
| `-da, --do-access-key` | DO Access Key |
| `-ds, --do-secret-key` | DO Secret Key |
| `-dn, --do-space` | DO Space name |
| `-dr, --do-region` | DO Region |
| `-dp, --do-path` | DO upload path (default: `backups`) |
| `-b, --backup-path` | Local backup path (default: `/opt/backups`) |

---

## Cron Setup

Run daily at 1:00 AM:
```bash
crontab -e
```
```
0 1 * * * /usr/local/bin/backup.sh -c mattermost-postgres-1
```

---

## Backup Storage

| Location | Retention |
|----------|-----------|
| Local (`/opt/backups/daily/`) | Last 3 days |
| DigitalOcean Spaces | All uploads (no auto-delete) |

---

## Install Script on Server

```bash
scp backup.sh root@<server-ip>:/usr/local/bin/backup.sh
chmod +x /usr/local/bin/backup.sh
```
