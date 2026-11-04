#!/bin/bash
# ApplicationStart: start the application process (python3 /opt/wsi-api/app.pyc)
set -e
systemctl daemon-reload
systemctl enable wsi-api
systemctl restart wsi-api
