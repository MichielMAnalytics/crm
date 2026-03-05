FROM frappe/bench:latest

USER frappe
WORKDIR /home/frappe

# Frappe v15 requires Python ≤3.12 (pypika 0.48.9 uses ast.Str removed in 3.12+)
RUN pyenv install 3.11 && pyenv global 3.11

# Initialize bench with Frappe v15
RUN bench init --skip-redis-config-generation --python $(pyenv which python3.11) frappe-bench --version version-15

WORKDIR /home/frappe/frappe-bench

# Install the CRM app from local source
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/crm

RUN bench get-app /home/frappe/frappe-bench/apps/crm

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
