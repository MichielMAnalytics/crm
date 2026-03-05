#!/bin/bash
set -e

cd /home/frappe/frappe-bench

# --- Redis: point all 3 Frappe redis connections at external Redis ---
if [ -n "$REDIS_URL" ]; then
    bench set-redis-cache-host "$REDIS_URL"
    bench set-redis-queue-host "$REDIS_URL"
    bench set-redis-socketio-host "$REDIS_URL"
fi

# Remove redis and watch from Procfile (external Redis, no file watcher needed)
sed -i '/^redis/d' ./Procfile
sed -i '/^watch/d' ./Procfile

# --- PostgreSQL: configure and initialize ---
if [ -n "$DB_HOST" ]; then
    python3 - << 'PYEOF'
import json, os

db_host = os.environ["DB_HOST"]
db_port = int(os.environ.get("DB_PORT", "5432"))
db_user = os.environ.get("DB_USER", "postgres")
db_password = os.environ.get("DB_PASSWORD", "")
db_name = os.environ.get("DB_NAME", "app")

# common_site_config.json
common_cfg_path = "sites/common_site_config.json"
with open(common_cfg_path) as f:
    common = json.load(f)
common["db_host"] = db_host
common["db_port"] = db_port
common["root_login"] = db_user
common["root_password"] = db_password
with open(common_cfg_path, "w") as f:
    json.dump(common, f, indent=1)

# site_config.json — set db_type to postgres and db_name
site_cfg_path = "sites/crm.localhost/site_config.json"
with open(site_cfg_path) as f:
    site = json.load(f)
site["db_host"] = db_host
site["db_port"] = db_port
site["db_type"] = "postgres"
site["db_name"] = db_name
with open(site_cfg_path, "w") as f:
    json.dump(site, f, indent=1)
PYEOF

    # Try migrate first (works if site DB already exists and is complete).
    if ! bench --site crm.localhost migrate 2>/dev/null; then
        echo "Migration failed — creating new site on external DB..."
        bench new-site crm.localhost \
            --force \
            --db-type postgres \
            --db-host "$DB_HOST" \
            --db-port "${DB_PORT:-5432}" \
            --db-root-username "$DB_USER" \
            --db-root-password "$DB_PASSWORD" \
            --admin-password "${ADMIN_PASSWORD:-admin}" \
            --db-name "${DB_NAME:-app}"

        bench --site crm.localhost install-app crm
        bench use crm.localhost
    fi

    bench --site crm.localhost set-config developer_mode 0
    bench --site crm.localhost set-config mute_emails 1
fi

exec bench start
