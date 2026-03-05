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

# --- MySQL: configure and initialize ---
if [ -n "$DB_HOST" ]; then
    bench set-mariadb-host "$DB_HOST"

    python3 - << 'PYEOF'
import json, os

db_host = os.environ["DB_HOST"]
db_port = int(os.environ.get("DB_PORT", "3306"))
db_password = os.environ.get("DB_PASSWORD", "")

# common_site_config.json — bench reads root_password from here
common_cfg_path = "sites/common_site_config.json"
with open(common_cfg_path) as f:
    common = json.load(f)
common["db_host"] = db_host
common["db_port"] = db_port
common["root_password"] = db_password
common["mariadb_user_host_login_scope"] = "%"
with open(common_cfg_path, "w") as f:
    json.dump(common, f, indent=1)

# site_config.json
site_cfg_path = "sites/crm.localhost/site_config.json"
with open(site_cfg_path) as f:
    site = json.load(f)
site["db_host"] = db_host
site["db_port"] = db_port
site["db_type"] = "mariadb"
with open(site_cfg_path, "w") as f:
    json.dump(site, f, indent=1)
PYEOF

    # Patch Frappe's MariaDB connector to relax sql_mode on every connection.
    # Frappe v16 expects MariaDB which allows default values on JSON/BLOB columns.
    # MySQL 8.0 blocks this with STRICT_TRANS_TABLES. We patch get_connection()
    # to SET SESSION sql_mode after each new connection.
    DBFILE="apps/frappe/frappe/database/mariadb/mysqlclient.py"
    if [ -f "$DBFILE" ] && ! grep -q "sql_mode patch" "$DBFILE"; then
        echo "Patching Frappe MariaDB connector for MySQL 8.0 compatibility..."
        ./env/bin/python3 - << 'PYEOF'
import re

path = "apps/frappe/frappe/database/mariadb/mysqlclient.py"
with open(path) as f:
    content = f.read()

# Patch get_connection() to set sql_mode after creating the connection
old = "conn.auto_reconnect = True\n\t\treturn conn"
new = """conn.auto_reconnect = True
\t\t# sql_mode patch: relax strict mode for MySQL 8.0 (Frappe expects MariaDB)
\t\ttry:
\t\t\t_cur = conn.cursor()
\t\t\t_cur.execute("SET SESSION sql_mode='ONLY_FULL_GROUP_BY,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'")
\t\t\t_cur.close()
\t\texcept Exception:
\t\t\tpass
\t\treturn conn"""

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Patched get_connection() successfully")
else:
    print("WARNING: Could not find patch target in mysqlclient.py")
PYEOF
    fi

    # Drop any incomplete database from a previous failed setup
    ./env/bin/python3 - << 'PYEOF'
import os, MySQLdb

conn = MySQLdb.connect(
    host=os.environ["DB_HOST"],
    port=int(os.environ.get("DB_PORT", "3306")),
    user=os.environ.get("DB_USER", "root"),
    passwd=os.environ.get("DB_PASSWORD", ""),
)
cur = conn.cursor()
# Set relaxed sql_mode for this session
cur.execute("SET SESSION sql_mode='ONLY_FULL_GROUP_BY,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'")

db_name = os.environ.get("DB_NAME", "_1bd39a7536094989")
cur.execute("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s", (db_name,))
if cur.fetchone():
    cur.execute("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s AND TABLE_NAME = 'tabDocType'", (db_name,))
    if cur.fetchone()[0] == 0:
        print(f"Database {db_name} is incomplete — dropping it")
        cur.execute(f"DROP DATABASE `{db_name}`")
        try:
            cur.execute(f"DROP USER IF EXISTS `{db_name}`@'%%'")
        except Exception:
            pass
        conn.commit()

cur.close()
conn.close()
PYEOF

    # Try migrate first (works if site DB already exists and is complete).
    if ! bench --site crm.localhost migrate 2>/dev/null; then
        echo "Migration failed — creating new site on external DB..."
        bench new-site crm.localhost \
            --force \
            --db-host "$DB_HOST" \
            --db-port "${DB_PORT:-3306}" \
            --mariadb-root-password "$DB_PASSWORD" \
            --admin-password "${ADMIN_PASSWORD:-admin}" \
            --mariadb-user-host-login-scope="%"

        bench --site crm.localhost install-app crm
        bench use crm.localhost
    fi

    bench --site crm.localhost set-config developer_mode 0
    bench --site crm.localhost set-config mute_emails 1
fi

exec bench start
