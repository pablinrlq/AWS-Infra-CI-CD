#!/bin/bash
# ValidateService: wait until GET /health answers HTTP 200
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1/health >/dev/null; then
    echo "GET /health OK"
    exit 0
  fi
  sleep 2
done
echo "GET /health failed"
systemctl status wsi-api --no-pager || true
exit 1
