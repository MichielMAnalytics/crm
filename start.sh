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
import json, os, sys

db_host = os.environ["DB_HOST"]
db_port = int(os.environ.get("DB_PORT", "5432"))
db_user = os.environ.get("DB_USER", "postgres")
db_password = os.environ.get("DB_PASSWORD", "")
db_name = os.environ.get("DB_NAME", "app")

# common_site_config.json — root credentials for bench new-site
common_cfg_path = "sites/common_site_config.json"
with open(common_cfg_path) as f:
    common = json.load(f)
common["db_host"] = db_host
common["db_port"] = db_port
common["root_login"] = db_user
common["root_password"] = db_password
with open(common_cfg_path, "w") as f:
    json.dump(common, f, indent=1)

# site_config.json — set db_type to postgres
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

    # Patch Frappe's PostgreSQL setup to connect to 'postgres' database for root
    # connection instead of using the root_login username as database name.
    # Frappe's get_root_connection() uses cur_db_name=frappe.flags.root_login, but
    # on managed PostgreSQL the user name doesn't match any database name.
    # Patch Frappe's PostgreSQL setup:
    # 1. Use 'postgres' database for root connection (user name != database name on managed PG)
    # 2. Terminate existing connections before DROP DATABASE
    SETUP_DB="apps/frappe/frappe/database/postgres/setup_db.py"
    if [ -f "$SETUP_DB" ] && ! grep -q "cur_db_name=\"postgres\"" "$SETUP_DB"; then
        ./env/bin/python3 - << 'PYEOF'
path = "apps/frappe/frappe/database/postgres/setup_db.py"
with open(path) as f:
    content = f.read()

# Fix 1: Use 'postgres' as root connection database
content = content.replace(
    'cur_db_name=frappe.flags.root_login',
    'cur_db_name="postgres"'
)

# Fix 2: Terminate connections before DROP DATABASE
content = content.replace(
    'root_conn.sql(f\'DROP DATABASE IF EXISTS "{frappe.conf.db_name}"\')',
    """root_conn.sql(f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{frappe.conf.db_name}' AND pid <> pg_backend_pid()")
\troot_conn.sql(f'DROP DATABASE IF EXISTS "{frappe.conf.db_name}"')"""
)

with open(path, "w") as f:
    f.write(content)
import sys
print("Patched setup_db.py", file=sys.stderr)
PYEOF
    fi

    # Wait for PostgreSQL to be ready
    for i in $(seq 1 30); do
        if ./env/bin/python3 -c "
import psycopg2, os, sys
try:
    conn = psycopg2.connect(
        host=os.environ['DB_HOST'],
        port=int(os.environ.get('DB_PORT', '5432')),
        user=os.environ.get('DB_USER', 'postgres'),
        password=os.environ.get('DB_PASSWORD', ''),
        dbname='postgres',
        connect_timeout=5,
    )
    conn.close()
    print('PostgreSQL is ready', file=sys.stderr)
except Exception as e:
    print(f'Waiting for PostgreSQL ({e})', file=sys.stderr)
    exit(1)
" 2>&1; then
            break
        fi
        sleep 2
    done

    # Try migrate first (works if site DB already exists and is complete).
    if ! bench --site crm.localhost migrate 2>/dev/null; then
        echo "Migration failed — creating new site on external DB..." >&2
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
