#!/bin/bash

# Script: PostgreSQL Database Backup
# Description: Automates daily PostgreSQL database backups stored locally and uploaded to DigitalOcean Spaces
# Usage: ./backup.sh (-c|--container <container_name> | -n|--native) [OPTIONS]

# Default values
CONTAINER_NAME=""
LOCAL_BACKUP_PATH="/opt/backups"
CONFIG_DIR="/etc/backup"
PG_CONFIG_FILE="$CONFIG_DIR/pg.conf"
DO_CONFIG_FILE="$CONFIG_DIR/do.conf"

# PostgreSQL credentials
PG_USER=""
PG_PASSWORD=""
PG_DATABASE=""
BACKUP_MODE=""
PG_HOST=""

# DigitalOcean Spaces credentials
DO_ACCESS_KEY=""
DO_SECRET_KEY=""
DO_SPACE=""
DO_REGION=""
DO_PATH="backups"

print_usage() {
    echo "Usage: $0 (-c|--container <container_name> | -n|--native) [OPTIONS]"
    echo "Required arguments:"
    echo "  -c, --container    Name of the PostgreSQL container"
    echo "  -n, --native       Use native PostgreSQL backup (requires database credentials)"
    echo ""
    echo "Native PostgreSQL Options:"
    echo "  --pg-host          PostgreSQL host address"
    echo "  --pg-user          PostgreSQL username"
    echo "  --pg-password      PostgreSQL password"
    echo "  --pg-database      PostgreSQL database name"
    echo ""
    echo "DigitalOcean Options:"
    echo "  -da, --do-access-key  DO Access Key"
    echo "  -ds, --do-secret-key  DO Secret Key"
    echo "  -dn, --do-space       DO Space name"
    echo "  -dr, --do-region      DO Region"
    echo "  -dp, --do-path        DO Path (default: backups)"
    echo ""
    echo "Other Options:"
    echo "  -b, --backup-path  Local backup path (default: /opt/backups)"
    exit 1
}

# upload_to_do(): Uploads backup file to DigitalOcean Spaces
upload_to_do() {
    local FILE=$1
    local FILENAME=$(basename "$FILE")

    echo "Uploading backup to DO Spaces: $FILENAME"
    AWS_ACCESS_KEY_ID=$DO_ACCESS_KEY \
    AWS_SECRET_ACCESS_KEY=$DO_SECRET_KEY \
    aws s3 cp "$FILE" "s3://$DO_SPACE/$DO_PATH/$FILENAME" \
        --endpoint-url "https://$DO_REGION.digitaloceanspaces.com" --quiet

    if [ $? -eq 0 ]; then
        echo "✅ Upload to DigitalOcean Spaces succeeded"
    else
        echo "❌ Upload to DigitalOcean Spaces failed"
    fi
}

# delete_todays_backup(): Removes any existing backup for today before creating a new one
delete_todays_backup() {
    local TODAY="$(date +%Y_%m_%d)"
    local EXISTING=$(find "$LOCAL_BACKUP_PATH/daily" -type f -name "backup_${TODAY}*.sql.gz")
    if [ ! -z "$EXISTING" ]; then
        echo "Removing existing backup for today..."
        echo "$EXISTING" | while read file; do
            echo "  - $(basename "$file")"
            rm "$file"
        done
    fi
}

# cleanup_old_backups(): Removes daily backups older than 3 days
cleanup_old_backups() {
    local RETENTION_DAYS=3
    echo "Cleaning up backups older than $RETENTION_DAYS days..."
    OLD_FILES=$(find "$LOCAL_BACKUP_PATH/daily" -type f -mtime +$RETENTION_DAYS)
    if [ ! -z "$OLD_FILES" ]; then
        echo "$OLD_FILES" | while read file; do
            echo "  - $(basename "$file")"
            rm "$file"
        done
    else
        echo "No old backups to clean up."
    fi
}

# perform_backup(): Creates backup (docker mode)
perform_backup() {
    echo "Creating daily backup..."

    if ! docker exec $CONTAINER_NAME which backup &> /dev/null; then
        echo "❌ Error: 'backup' command not found in container $CONTAINER_NAME"
        return 1
    fi

    if ! docker exec $CONTAINER_NAME backup; then
        echo "❌ Error: backup command failed in container $CONTAINER_NAME"
        return 1
    fi

    LATEST_BACKUP_NAME=$(docker exec $CONTAINER_NAME ls -t /backups/ | grep "backup_.*\.sql\.gz" | head -n1 | tr -d '\r')

    if [ ! -z "$LATEST_BACKUP_NAME" ]; then
        BACKUP_PATH="$LOCAL_BACKUP_PATH/daily/$LATEST_BACKUP_NAME"
        echo "Copying '$LATEST_BACKUP_NAME' from container..."
        docker cp "$CONTAINER_NAME:/backups/$LATEST_BACKUP_NAME" "$BACKUP_PATH"

        if [ -f "$BACKUP_PATH" ]; then
            echo "✅ Daily backup saved: $(basename "$BACKUP_PATH")"
            upload_to_do "$BACKUP_PATH"
        else
            echo "❌ Failed to copy daily backup from container"
        fi
    else
        echo "❌ No backup file found in container"
    fi
}

generate_backup_filename() {
    echo "backup_$(date +%Y_%m_%dT%H_%M_%S)"
}

perform_native_backup() {
    local BACKUP_FILE=$(generate_backup_filename)
    local DEST_DIR="$LOCAL_BACKUP_PATH/daily"

    echo "Creating native PostgreSQL daily backup..."

    PGPASSWORD="$PG_PASSWORD" pg_dump -h "$PG_HOST" -U "$PG_USER" -d "$PG_DATABASE" > "$DEST_DIR/$BACKUP_FILE.sql"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to create PostgreSQL backup"
        return 1
    fi

    gzip "$DEST_DIR/$BACKUP_FILE.sql"
    echo "✅ Daily backup saved: $BACKUP_FILE.sql.gz"
    upload_to_do "$DEST_DIR/$BACKUP_FILE.sql.gz"
}

load_config_files() {
    if [ -f "$PG_CONFIG_FILE" ] && [ -z "$PG_USER" ]; then
        echo "Loading PostgreSQL credentials from $PG_CONFIG_FILE"
        source "$PG_CONFIG_FILE"
    fi

    if [ -f "$DO_CONFIG_FILE" ] && [ -z "$DO_ACCESS_KEY" ]; then
        echo "Loading DO credentials from $DO_CONFIG_FILE"
        source "$DO_CONFIG_FILE"
    fi
}

# Main script execution
#######################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--container)
            CONTAINER_NAME="$2"
            BACKUP_MODE="docker"
            shift 2
            ;;
        -n|--native)
            BACKUP_MODE="native"
            shift
            ;;
        --pg-host)
            PG_HOST="$2"
            shift 2
            ;;
        --pg-user)
            PG_USER="$2"
            shift 2
            ;;
        --pg-password)
            PG_PASSWORD="$2"
            shift 2
            ;;
        --pg-database)
            PG_DATABASE="$2"
            shift 2
            ;;
        -da|--do-access-key)
            DO_ACCESS_KEY="$2"
            shift 2
            ;;
        -ds|--do-secret-key)
            DO_SECRET_KEY="$2"
            shift 2
            ;;
        -dn|--do-space)
            DO_SPACE="$2"
            shift 2
            ;;
        -dr|--do-region)
            DO_REGION="$2"
            shift 2
            ;;
        -dp|--do-path)
            DO_PATH="$2"
            shift 2
            ;;
        -b|--backup-path)
            LOCAL_BACKUP_PATH="$2"
            shift 2
            ;;
        *)
            print_usage
            ;;
    esac
done

if [ -z "$BACKUP_MODE" ]; then
    echo "Error: Backup mode (--container or --native) is required"
    print_usage
fi

load_config_files

if [ "$BACKUP_MODE" = "native" ]; then
    if [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ] || [ -z "$PG_DATABASE" ] || [ -z "$PG_HOST" ]; then
        echo "Error: PostgreSQL credentials are required. Either:"
        echo "  1. Provide them as arguments, or"
        echo "  2. Create $PG_CONFIG_FILE with:"
        echo "     PG_USER='your_user'"
        echo "     PG_PASSWORD='your_password'"
        echo "     PG_DATABASE='your_database'"
        echo "     PG_HOST='your_host'"
        print_usage
    fi

    if ! command -v pg_dump &> /dev/null; then
        echo "Error: pg_dump not found. Please install PostgreSQL client tools."
        exit 1
    fi
fi

# Validate DO credentials
if [ -z "$DO_ACCESS_KEY" ] || [ -z "$DO_SECRET_KEY" ] || [ -z "$DO_SPACE" ] || [ -z "$DO_REGION" ]; then
    echo "Error: DO credentials are required. Either:"
    echo "  1. Provide them as arguments, or"
    echo "  2. Create $DO_CONFIG_FILE with:"
    echo "     DO_ACCESS_KEY='your_access_key'"
    echo "     DO_SECRET_KEY='your_secret_key'"
    echo "     DO_SPACE='your_space_name'"
    echo "     DO_REGION='your_region'"
    print_usage
fi

# Check if AWS CLI is installed (used for DO Spaces via S3-compatible API)
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed"
    echo "Installing AWS CLI..."

    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws/

    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI installation failed"
        exit 1
    fi
    echo "AWS CLI installed successfully"
fi

if [ "$BACKUP_MODE" = "docker" ] && ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed"
    exit 1
fi

# Create all required directories
echo "Ensuring required directories exist..."
for dir in "$LOCAL_BACKUP_PATH" "$LOCAL_BACKUP_PATH/daily" "$CONFIG_DIR"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        if [ $? -eq 0 ]; then
            echo "  ✅ Created: $dir"
        else
            echo "  ❌ Failed to create: $dir"
            exit 1
        fi
    fi
done

# Execute backup process
echo "Starting backup process at $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo "Storage: Local + DigitalOcean Spaces ($DO_SPACE)"

# Remove today's existing backup before creating a new one
delete_todays_backup

if [ "$BACKUP_MODE" = "docker" ]; then
    docker exec $CONTAINER_NAME mkdir -p "/backups/daily"
    perform_backup
else
    perform_native_backup
fi

cleanup_old_backups

echo "Backup process completed at $(date '+%Y-%m-%d %H:%M:%S')"
