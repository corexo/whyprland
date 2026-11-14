# womarchy WSL leaf: system services for WSL.
# WSL owns networking (eth0, /etc/resolv.conf, DNS tunnelling) and there is no
# seat, printer, Bluetooth adapter, battery or display manager to serve. Masks
# follow Microsoft's custom-distro guidance and the archlinux-wsl image.
#
# WOMARCHY_DOCKER comes from /etc/womarchy/config via womarchy-apply-system, so
# every update (womarchy-update) reasserts the user's choice.
# Every unit womarchy masks is recorded in /var/lib/womarchy/masked-units. A
# recorded unit that is no longer masked was unmasked on purpose (masking cannot
# be undone by a mere `systemctl enable`): it is recorded as released and never
# masked again.
set -euo pipefail

state=/var/lib/womarchy
masked_list=$state/masked-units
released_list=$state/released-units
install -d -m 0755 "$state"
touch "$masked_list" "$released_list"

docker=${WOMARCHY_DOCKER:-1}

# docker.socket is socket-activated (costs nothing until used).
if [[ -f /usr/lib/systemd/system/docker.socket ]]; then
  if [[ $docker == 1 ]]; then
    systemctl enable docker.socket
  else
    systemctl disable docker.socket 2>/dev/null || true   # Docker Desktop's WSL integration instead
  fi
fi
# systemd-oomd needs PSI + cgroup v2, both present in the WSL kernel.
systemctl enable systemd-oomd.service 2>/dev/null || true

# Units that fight WSL or have nothing to manage. Masked (not just disabled) so
# package updates re-enabling them cannot start them.
mask=(
  NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service
  systemd-resolved.service
  systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
  iwd.service wpa_supplicant.service
  sddm.service plymouth-start.service plymouth-quit.service plymouth-quit-wait.service
  cups.service cups.socket cups.path cups-browsed.service
  avahi-daemon.service avahi-daemon.socket
  power-profiles-daemon.service bluetooth.service
  linux-modules-cleanup.service
  # Same as the official Arch WSL image (WSL provides the consoles and first boot;
  # getty templates fail on WSL's shared Hyper-V consoles, microsoft/WSL#13595).
  # tmpfiles/tmp.mount stay enabled there and work, so they stay enabled here.
  console-getty.service systemd-firstboot.service getty@.service serial-getty@.service
)

is_masked() { [[ $(readlink "/etc/systemd/system/$1" 2>/dev/null) == /dev/null ]]; }

for unit in "${mask[@]}"; do
  link=/etc/systemd/system/$unit
  grep -qx "$unit" "$released_list" && continue
  if grep -qx "$unit" "$masked_list"; then
    if ! is_masked "$unit"; then
      echo "note: $unit was unmasked after womarchy masked it; leaving it unmasked from now on"
      echo "$unit" >>"$released_list"
    fi
    continue
  fi
  # Never replace a real unit file an admin put in /etc.
  [[ -e $link && ! -L $link ]] && continue
  ln -sfn /dev/null "$link"
  echo "$unit" >>"$masked_list"
done
