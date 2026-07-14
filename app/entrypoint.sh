#!/usr/bin/env sh
# witness app entrypoint
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
set -eu

# Create the ledger table before accepting traffic. Retried, because on a cold
# stack the pods are routinely Running before RDS finishes coming up, and a
# crash-loop through that window pollutes the very metrics being measured.
python - <<'PY'
import logging, sys, time
from main import init_schema

logging.basicConfig(level=logging.INFO)

for attempt in range(30):
    try:
        init_schema()
        sys.exit(0)
    except Exception as exc:  # noqa: BLE001
        logging.warning("schema bootstrap attempt %s/30 failed: %s", attempt + 1, exc)
        time.sleep(2)

logging.error("database unreachable after 60s, giving up")
sys.exit(1)
PY

# --workers 2 --threads 4: the endpoints are I/O-bound on Postgres, so threads
# are the right shape. More importantly --timeout 30 is longer than an RDS
# failover's worst-case stall, so gunicorn does not shoot its own worker in the
# head halfway through a failover and turn a survivable blip into a restart.
exec gunicorn \
  --bind 0.0.0.0:8080 \
  --workers 2 \
  --threads 4 \
  --timeout 30 \
  --graceful-timeout 10 \
  --access-logfile - \
  --error-logfile - \
  main:app
