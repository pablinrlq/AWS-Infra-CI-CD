#!/bin/bash
# ApplicationStop: stop the application if it is running
if systemctl list-unit-files 2>/dev/null | grep -q '^wsi-api.service'; then
  systemctl stop wsi-api || true
fi
exit 0
