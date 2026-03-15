
---

# 2️⃣ Validation script 

`validate-install.sh`

```bash
#!/usr/bin/env bash

echo "=== XRDP status ==="
systemctl status xrdp --no-pager | head -n 10

echo
echo "=== XRDP port ==="
grep port /etc/xrdp/xrdp.ini

echo
echo "=== XRDP session ==="
cat ~/.xsession

echo
echo "=== Hyper-V modules ==="
lsmod | grep hv

echo
echo "=== XFCE installed ==="
dpkg -l | grep xfce4 | head