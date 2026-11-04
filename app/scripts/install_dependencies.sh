#!/bin/bash
# BeforeInstall: prepare a brand-new Amazon Linux 2 instance to run app.pyc.
# The instances have no internet access (private subnet, no NAT): python3 comes from the
# Amazon Linux repos through the S3 gateway endpoint, and Flask is not installed here -
# it is shipped in the artifact (/opt/wsi-api/vendor, see buildspec.yml).
set -eo pipefail

# Python 3 (Amazon Linux 2 system python3 - the same interpreter version CodeBuild
# uses to compile app.pyc, so the bytecode magic number matches)
if ! rpm -q python3 >/dev/null 2>&1; then
  for i in $(seq 1 10); do yum install -y python3 && break; sleep 10; done
fi
rpm -q python3

mkdir -p /opt/wsi-api

# systemd service: runs the compiled app.pyc with the shipped libraries (vendor/),
# restarts it on failure and after reboot
cat > /etc/systemd/system/wsi-api.service <<'UNIT'
[Unit]
Description=wsi-api (Python / Flask - compiled app.pyc)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/wsi-api
Environment=PYTHONPATH=/opt/wsi-api/vendor
ExecStart=/usr/bin/python3 /opt/wsi-api/app.pyc
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
