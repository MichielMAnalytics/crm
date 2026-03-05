FROM frappe/bench:latest

USER frappe
WORKDIR /home/frappe

# Initialize bench with Frappe v16 (matches CRM's frappe-dependencies: >=16.0.0-dev)
RUN bench init --skip-redis-config-generation frappe-bench --version version-16

WORKDIR /home/frappe/frappe-bench

# Install the CRM app (COPY strips .git, so install manually instead of bench get-app)
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/crm

RUN cd /home/frappe/frappe-bench && \
    ./env/bin/pip install -e apps/crm && \
    echo "crm" >> sites/apps.txt && \
    bench build --app crm

# Create site (uses SQLite for initial setup, will be reconfigured at runtime)
RUN bench new-site crm.localhost \
    --db-type sqlite \
    --admin-password admin \
    --no-mariadb-socket || true

RUN bench --site crm.localhost install-app crm || true
RUN bench use crm.localhost

# Configure for production-like setup
RUN bench --site crm.localhost set-config developer_mode 0
RUN bench --site crm.localhost set-config mute_emails 1

EXPOSE 8000

CMD ["bench", "start"]
