#!/usr/bin/env bash
set -euo pipefail

echo "== Hyper-V Enhanced Session setup (XRDP + XFCE + vsock) =="

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:"
  echo "  sudo bash setup-hyperv-enhanced-xfce.sh"
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" ]]; then
  echo "Could not determine desktop user. Run with sudo from your normal user account."
  exit 1
fi

USER_HOME="$(eval echo "~${TARGET_USER}")"

echo
echo "== Detected user = ${TARGET_USER}"
echo "== Home        = ${USER_HOME}"

echo
echo "== Updating packages =="
apt-get update

echo
echo "== Installing required packages =="
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xrdp \
  xorgxrdp \
  xfce4 \
  xfce4-goodies \
  dbus-x11 \
  x11-xserver-utils \
  light-locker

echo
echo "== Adding xrdp user to ssl-cert group =="
adduser xrdp ssl-cert || true

echo
echo "== Disabling Wayland =="
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "${GDM_CONF}" ]]; then
  cp "${GDM_CONF}" "${GDM_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  if grep -qE '^\s*#?\s*WaylandEnable=' "${GDM_CONF}"; then
    sed -i 's/^\s*#\?\s*WaylandEnable=.*/WaylandEnable=false/' "${GDM_CONF}"
  else
    printf '\nWaylandEnable=false\n' >> "${GDM_CONF}"
  fi
fi

echo
echo "== Disabling gnome-remote-desktop if present =="
runuser -l "${TARGET_USER}" -c 'systemctl --user disable --now gnome-remote-desktop.service' >/dev/null 2>&1 || true

echo
echo "== Writing XRDP session files for user =="
cat > "${USER_HOME}/.xsession" <<'EOF'
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF

cat > "${USER_HOME}/.xsessionrc" <<'EOF'
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
EOF

rm -f "${USER_HOME}/.xrdp-startwm.sh" || true
chown "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.xsession" "${USER_HOME}/.xsessionrc"
chmod 744 "${USER_HOME}/.xsession"
chmod 644 "${USER_HOME}/.xsessionrc"

echo
echo "== Tweaking startwm.sh for XFCE-friendly startup =="
STARTWM="/etc/xrdp/startwm.sh"
cp "${STARTWM}" "${STARTWM}.bak.$(date +%Y%m%d%H%M%S)" || true

cat > "${STARTWM}" <<'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

if [ -r /etc/profile ]; then
  . /etc/profile
fi

if [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

if [ -r "$HOME/.xsession" ]; then
  exec /bin/sh "$HOME/.xsession"
fi

exec startxfce4
EOF

chmod 755 "${STARTWM}"

echo
echo "== Configuring XRDP for Hyper-V vsock =="
XRDP_INI="/etc/xrdp/xrdp.ini"
cp "${XRDP_INI}" "${XRDP_INI}.bak.$(date +%Y%m%d%H%M%S)"

python3 <<'PY'
from pathlib import Path
import re

p = Path("/etc/xrdp/xrdp.ini")
text = p.read_text()

def replace_or_add(text, key, value):
    pattern = rf'^\s*{re.escape(key)}=.*$'
    repl = f'{key}={value}'
    if re.search(pattern, text, flags=re.M):
        return re.sub(pattern, repl, text, flags=re.M)
    marker = "[Globals]"
    idx = text.find(marker)
    if idx >= 0:
        insert_at = text.find("\n", idx)
        return text[:insert_at+1] + repl + "\n" + text[insert_at+1:]
    return text + "\n" + repl + "\n"

text = replace_or_add(text, "port", "vsock://-1:3389")
text = replace_or_add(text, "use_vsock", "true")
text = replace_or_add(text, "security_layer", "negotiate")
text = replace_or_add(text, "crypt_level", "high")
p.write_text(text)
PY

echo
echo "== Ensuring Xorg backend exists in sesman.ini =="
SESMAN_INI="/etc/xrdp/sesman.ini"
if ! grep -q '^\[Xorg\]' "${SESMAN_INI}"; then
  cat >> "${SESMAN_INI}" <<'EOF'

[Xorg]
param=/usr/lib/xorg/Xorg
EOF
fi

echo
echo "== Commenting problematic pam_gnome_keyring lines if present =="
PAM_FILE="/etc/pam.d/xrdp-sesman"
if [[ -f "${PAM_FILE}" ]]; then
  sed -i 's/^\s*auth\s\+optional\s\+pam_gnome_keyring\.so/#&/' "${PAM_FILE}" || true
  sed -i 's/^\s*session\s\+optional\s\+pam_gnome_keyring\.so/#&/' "${PAM_FILE}" || true
fi

echo
echo "== Fixing XRDP cert/key permissions if present =="
[[ -f /etc/xrdp/cert.pem ]] && chmod 600 /etc/xrdp/cert.pem || true
[[ -f /etc/xrdp/key.pem  ]] && chmod 640 /etc/xrdp/key.pem  || true

echo
echo "== Enabling services =="
systemctl enable xrdp
systemctl enable xrdp-sesman

echo
echo "== Restarting services =="
systemctl restart xrdp
systemctl restart xrdp-sesman

echo
echo "== Validation =="
systemctl --no-pager --full status xrdp | sed -n '1,20p' || true
echo
systemctl --no-pager --full status xrdp-sesman | sed -n '1,20p' || true
echo
echo "-- xrdp.ini relevant lines --"
grep -E '^\s*(port|use_vsock|security_layer|crypt_level)=' /etc/xrdp/xrdp.ini || true
echo
echo "-- user session file --"
sed -n '1,20p' "${USER_HOME}/.xsession" || true

echo
echo "== Done =="
echo "Next steps:"
echo "1. In Windows host, verify:"
echo '   Get-VMHost | fl EnableEnhancedSessionMode'
echo '   Get-VM -Name "ubuntu_vm" | fl Name,EnhancedSessionTransportType'
echo "2. Reboot the VM:"
echo "   sudo reboot"
echo "3. Reconnect from Hyper-V Manager"
echo "4. Login with:"
echo "   user: ${TARGET_USER}"
echo "   session: Xorg"