#!/bin/bash
# Build the whyprland image (Arch Linux + plain Hyprland on WSL): out/Whyprland-<date>.wsl
#
# Run as root inside the womarchy-build distro (see README.md):
#   wsl -d womarchy-build -u root -e bash <repo>/linux/image/build-image.sh
# Environment:
#   OUT=<dir>        output dir (default <repo>/out); womarchy packages are read from $OUT/repo
#   WORK=<dir>       scratch on a Linux filesystem (default /var/tmp/womarchy-image)
#   CACHE=<dir>      persistent package cache (default /var/cache/womarchy-pkg)
#   KEEP_ROOTFS=1    keep $WORK/rootfs after packing (for inspection)
#   XZ_LEVEL=6       xz preset
#   ALLOW_STOCK_PACKAGES=1  build even if $OUT/repo lacks aquamarine, hyprland, mesa or
#                    womarchy-session (the image then gets stock Arch builds; not a product image)
#   ALLOW_UNSIGNED_REPO=1   accept an unsigned $OUT/repo (lab images only, never a release)
#
# $OUT/repo is the [womarchy] repo as published: packages built by
# linux/packages/build-all.sh (including womarchy-compat and womarchy-keyring),
# db and packages signed by CI, fetched with linux/packages/fetch-signed-db.sh.
# Steps: verify and stage the signed [womarchy] repo -> trust womarchy's signing
# key (pinned fingerprint) -> pacstrap from the Arch Linux Archive snapshot
# ARCH_SNAPSHOT (pins.env) with [womarchy] first -> womarchy-apply-system in the
# chroot -> WSL config -> scrub machine-specific state -> tar | xz.
set -euo pipefail
export TZ=UTC LC_ALL=C.UTF-8
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=${OUT:-$REPO/out}
WORK=${WORK:-/var/tmp/womarchy-image}
CACHE=${CACHE:-/var/cache/womarchy-pkg}
XZ_LEVEL=${XZ_LEVEL:-6}
ALLOW_STOCK_PACKAGES=${ALLOW_STOCK_PACKAGES:-0}
ALLOW_UNSIGNED_REPO=${ALLOW_UNSIGNED_REPO:-0}
ROOTFS=$WORK/rootfs
STAGE_REPO=$WORK/repo
IMAGE_REPO=/var/lib/womarchy/repo   # the installed system's local [womarchy] repo (see wsl/pacman.sh)
BUILD_DATE=$(date -u +%Y%m%d)

source "$HERE/pins.env"             # WOMARCHY_KEY_FPR (pinned signing key), ARCH_SNAPSHOT (archive date)
KEY_DIR=$REPO/linux/packages/womarchy-keyring
ARCH_MIRROR="https://archive.archlinux.org/repos/$ARCH_SNAPSHOT/\$repo/os/\$arch"   # frozen: same packages every build
# Packages that must come from $OUT/repo (DRM-free compositor, patched Mesa, session).
REQUIRED_WOMARCHY=(womarchy-compat womarchy-keyring womarchy-session aquamarine hyprland mesa)
STOCK_ALTERNATIVE=(womarchy-session aquamarine hyprland mesa)   # what ALLOW_STOCK_PACKAGES may waive

# The image's packages (besides the [womarchy] ones). PipeWire tunnels to WSLg
# (wsl/audio.sh); Mesa d3d12 + Dozen Vulkan instead of vendor GPU drivers;
# mesa-utils for eglinfo GPU checks. No hyprlock/hypridle: Windows locks the session.
PACKAGES=(base base-devel sudo git nano vim
          hyprland uwsm xdg-desktop-portal-hyprland hyprpolkitagent waybar fuzzel mako kitty
          wl-clipboard grim slurp
          noto-fonts ttf-jetbrains-mono-nerd   # noto-fonts first, so it (not gnu-free-fonts) provides ttf-font
          pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire libpulse wireplumber
          mesa vulkan-dzn vulkan-icd-loader mesa-utils xorg-xwayland qt6-wayland
          womarchy-keyring womarchy-compat)

log() { printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
die() { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (inside the womarchy-build distro)"
[[ $ARCH_SNAPSHOT =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || die "bad ARCH_SNAPSHOT '$ARCH_SNAPSHOT' in pins.env"
for c in pacstrap arch-chroot bsdtar jq xz curl gpg findmnt; do
  command -v "$c" >/dev/null || die "missing $c (run linux/image/setup-build-distro.sh)"
done
[[ $ROOTFS == /*/* && $ROOTFS != *..* ]] || die "refusing odd ROOTFS path '$ROOTFS'"

# Mounts at or below $ROOTFS (pacstrap/arch-chroot bind /dev, /proc, /sys, /run there).
rootfs_mounts() { findmnt -rn -o TARGET | awk -v r="$ROOTFS" '$0 == r || index($0, r "/") == 1'; }
unmount_rootfs() {
  local m
  for m in $(rootfs_mounts | sort -r); do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
}
# A /dev bind left under $ROOTFS would make `rm -rf` delete the device nodes every
# distro in the WSL VM shares: never delete while anything is still mounted there.
remove_rootfs() {
  unmount_rootfs
  local left
  left=$(rootfs_mounts)
  [[ -z $left ]] || die "still mounted under $ROOTFS, not deleting: $(paste -sd' ' <<<"$left")"
  rm -rf --one-file-system "$ROOTFS"
}
trap unmount_rootfs EXIT

# Owned by root, no group/other write: the [womarchy] repo is trusted (TrustAll)
# and comes first, so a writable copy would let any user plant packages for root.
lock_down() {
  chown -R root:root "$1"
  chmod -R u=rwX,go=rX "$1"
  rm -f "$1"/*.old
}

mkdir -p "$WORK" "$CACHE" "$OUT"
remove_rootfs
rm -rf --one-file-system "$STAGE_REPO" "$WORK/pkg"
mkdir -p "$ROOTFS" "$STAGE_REPO"

# --- 1. [womarchy] repo: $OUT/repo exactly as published (db + packages signed by CI) ---
log "Staging the [womarchy] repo"
[[ -f $OUT/repo/womarchy.db ]] ||
  die "no $OUT/repo/womarchy.db: build packages with linux/packages/build-all.sh, then fetch the signed db (linux/packages/fetch-signed-db.sh)"
if (( ALLOW_UNSIGNED_REPO )); then
  echo "warning: ALLOW_UNSIGNED_REPO=1: [womarchy] signatures are not checked (lab image, never a release)" >&2
else
  "$REPO/linux/packages/fetch-signed-db.sh" --verify-only "$OUT/repo" ||
    die "$OUT/repo is not a validly signed womarchy repo (see linux/packages/fetch-signed-db.sh)"
fi
# -L: real files for repo-add's womarchy.db -> womarchy.db.tar.gz links;
# --no-preserve: a drvfs (/mnt/d) copy would otherwise carry 0777 modes.
cp -rL --no-preserve=mode,ownership "$OUT/repo/." "$STAGE_REPO/"
lock_down "$STAGE_REPO"

# Repo contents, read once into a variable (no `| grep -q` under pipefail: an early
# grep exit SIGPIPEs the producer and the test silently fails).
repo_listing=$(bsdtar -tf "$STAGE_REPO/womarchy.db")
repo_version() { sed -n "s|^$1-\([^-/]*-[^-/]*\)/\$|\1|p" <<<"$repo_listing"; }
echo "womarchy repo: $(grep -c '/$' <<<"$repo_listing") packages"
# Every package the db lists must have its file (%FILENAME%) in the repo.
repo_files=$(bsdtar -xOf "$STAGE_REPO/womarchy.db" '*/desc' | awk '/^%FILENAME%$/ { getline; print }')
while IFS= read -r f; do
  [[ -z $f || -f $STAGE_REPO/$f ]] || die "the womarchy db lists $f, but the file is not in the repo"
done <<<"$repo_files"
missing=()
for p in "${REQUIRED_WOMARCHY[@]}"; do
  [[ -n $(repo_version "$p") ]] && continue
  [[ " ${STOCK_ALTERNATIVE[*]} " == *" $p "* ]] || die "$OUT/repo lacks $p (build it with linux/packages/build-all.sh)"
  missing+=("$p")
done
if ((${#missing[@]})); then
  (( ALLOW_STOCK_PACKAGES )) || die "$OUT/repo lacks ${missing[*]} (set ALLOW_STOCK_PACKAGES=1 to build with stock Arch packages)"
  echo "warning: building without womarchy ${missing[*]} (ALLOW_STOCK_PACKAGES=1)" >&2
fi

# --- 3. trust the womarchy repo key on the build host (pinned fingerprint) -----------
primaries() { gpg --show-keys --with-colons "$1" 2>/dev/null |
  awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' | sort -u; }
key_trusted=$(sed -e 's/#.*//' "$KEY_DIR/womarchy-trusted" | cut -d: -f1 | grep -E '^[0-9A-F]{40}$' | sort -u || true)
[[ $key_trusted == "$WOMARCHY_KEY_FPR" ]] || die "womarchy-trusted lists {${key_trusted//$'
'/,}}, expected exactly $WOMARCHY_KEY_FPR"
[[ $(primaries "$KEY_DIR/womarchy.asc") == "$WOMARCHY_KEY_FPR" ]] || die "womarchy.asc is not exactly the pinned key $WOMARCHY_KEY_FPR"
if (( ALLOW_UNSIGNED_REPO )); then
  womarchy_siglevel='Optional TrustAll'
else
  womarchy_siglevel='PackageOptional DatabaseRequired'
  pacman-key --add "$KEY_DIR/womarchy.asc" >/dev/null 2>&1 || die "cannot add the womarchy key to the build host's keyring"
  pacman-key --lsign-key "$WOMARCHY_KEY_FPR" >/dev/null 2>&1 || die "cannot locally sign the womarchy key"
fi

# Same-named package files from earlier local builds must not shadow the published ones.
while IFS= read -r f; do [[ -n $f ]] && rm -f "$CACHE/$f" "$CACHE/$f.sig"; done <<<"$repo_files"

# --- 4. pacstrap ---------------------------------------------------------------------
conf=$WORK/pacman.conf
{
  echo "[options]"
  echo "Architecture = auto"
  echo "SigLevel = Required DatabaseOptional"
  echo "LocalFileSigLevel = Optional"
  echo "ParallelDownloads = 5"
  echo "CacheDir = $CACHE/"
  echo
  echo "# [womarchy] first: its hyprland/aquamarine/mesa builds replace Arch's."
  echo "[womarchy]"
  echo "SigLevel = $womarchy_siglevel"
  echo "Server = file://$STAGE_REPO"
  for r in core extra; do printf '\n[%s]\nServer = %s\n' "$r" "$ARCH_MIRROR"; done
} >"$conf"

session=()
[[ -n $(repo_version womarchy-session) ]] && session=(womarchy-session)

log "pacstrap: ${#PACKAGES[@]} packages from the Arch archive of $ARCH_SNAPSHOT + womarchy"
nice -n 10 pacstrap -C "$conf" -c -G -M "$ROOTFS" "${PACKAGES[@]}" "${session[@]}"

# The womarchy builds must be what got installed (repo order is what decides).
for p in "${REQUIRED_WOMARCHY[@]}"; do
  want=$(repo_version "$p")
  [[ -n $want ]] || continue
  have=$(pacman -r "$ROOTFS" -Q "$p" 2>/dev/null | awk '{print $2}')
  [[ $have == "$want" ]] || die "$p: installed '${have:-none}', expected womarchy's $want"
done

# The shipped sync db carries its signature (pacman keeps womarchy.db.sig next to it).
if (( ! ALLOW_UNSIGNED_REPO )); then
  sync=$ROOTFS/var/lib/pacman/sync
  pacman-key --verify "$sync/womarchy.db.sig" "$sync/womarchy.db" >/dev/null 2>&1 ||
    die "the image's sync db $sync/womarchy.db has no valid signature"
fi

# --- 5. configure the system -----------------------------------------------------------
log "Configuring the image"
install -m 0644 "$HERE/rootfs/etc/wsl.conf" "$ROOTFS/etc/wsl.conf"
install -m 0644 "$HERE/rootfs/etc/wsl-distribution.conf" "$ROOTFS/etc/wsl-distribution.conf"
install -d -m 0755 "$ROOTFS/etc/womarchy"
cat >"$ROOTFS/etc/womarchy/profile" <<EOF
WOMARCHY_BUILD_DATE=$BUILD_DATE
WOMARCHY_ARCH_SNAPSHOT=$ARCH_SNAPSHOT
EOF
install -m 0644 "$HERE/rootfs/etc/womarchy/config" "$ROOTFS/etc/womarchy/config"

# The installed system's local [womarchy] repo (offline fallback behind the
# hosted one; see wsl/pacman.sh). /var/lib, not /var/cache: cache cleaners must
# not be able to remove a configured repo.
install -d -m 0755 "$ROOTFS/var/lib/womarchy" "$ROOTFS$IMAGE_REPO"
cp -r --no-preserve=mode,ownership "$STAGE_REPO/." "$ROOTFS$IMAGE_REPO/"
lock_down "$ROOTFS$IMAGE_REPO"
if (( ! ALLOW_UNSIGNED_REPO )); then
  pacman-key --verify "$ROOTFS$IMAGE_REPO/womarchy.db.sig" "$ROOTFS$IMAGE_REPO/womarchy.db" >/dev/null 2>&1 ||
    die "the image's local repo db has no valid signature"
fi

log "womarchy-apply-system in the chroot"
mountpoint -q "$ROOTFS" || mount --bind "$ROOTFS" "$ROOTFS"   # arch-chroot wants a mountpoint
arch-chroot "$ROOTFS" env WOMARCHY_XKB_LAYOUT=us WOMARCHY_LOCALE=en_US.UTF-8 womarchy-apply-system ||
  { cat "$ROOTFS/var/log/womarchy-apply-system.log" >&2; die "womarchy-apply-system failed in the chroot"; }

# Sanity: the things the image must have.
first_repo=$(grep -m1 -E '^\[[A-Za-z0-9_-]+\]' <(grep -v '^\[options\]' "$ROOTFS/etc/pacman.conf"))
[[ $first_repo == "[womarchy]" ]] || die "first pacman repo is '$first_repo', not [womarchy]"
[[ -L $ROOTFS/etc/systemd/system/NetworkManager.service || ! -f $ROOTFS/usr/lib/systemd/system/NetworkManager.service ]] ||
  die "NetworkManager not masked"
installed=$(pacman -r "$ROOTFS" -Qq)
for p in hyprland uwsm womarchy-compat womarchy-keyring mesa vulkan-dzn pipewire-pulse wireplumber; do
  grep -qx "$p" <<<"$installed" || die "package $p not installed"
done
for p in limine snapper linux; do
  if grep -qx "$p" <<<"$installed"; then die "$p must not be installed"; fi
done
omarchy_pkgs=$(grep -i '^omarchy' <<<"$installed" || true)
[[ -z $omarchy_pkgs ]] || die "Omarchy packages must not be installed: $(paste -sd' ' <<<"$omarchy_pkgs")"
writable=$(find "$ROOTFS$IMAGE_REPO" \( -perm /022 -o ! -user root \) ! -type l)
[[ -z $writable ]] || die "group/other-writable or non-root files in $IMAGE_REPO: $writable"

# --- 6. scrub machine-specific state (archlinux-wsl recipe) ------------------------------
log "Scrubbing"
rm -rf "$ROOTFS/etc/pacman.d/gnupg"            # never ship a private key; OOBE runs pacman-key --init
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id" "$ROOTFS/etc/hostname"
rm -f "$ROOTFS/etc/resolv.conf"                # WSL generates it
# Sync DBs are kept: they describe exactly the archive snapshot the image was
# built from (no partial-upgrade risk), and without them every pacman call warns
# "database file ... does not exist" until the first `pacman -Syu` (womarchy-update).
rm -rf "$ROOTFS"/var/cache/pacman/pkg/* "$ROOTFS"/var/log/journal/*
rm -rf "$ROOTFS"/root/* "$ROOTFS"/root/.[!.]* "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/*
rm -rf "$ROOTFS/var/lib/womarchy/rollback"     # build-time points (pacstrap's 2nd transaction)
# Backup files (repo-add's *.old, pacman's *.pacsave/*.pacnew) have no place in
# an image; a package-owned file of that name is reported, not deleted.
while IFS= read -r -d '' f; do
  if pacman -r "$ROOTFS" -Qqo "${f#"$ROOTFS"}" &>/dev/null; then
    echo "note: keeping package-owned ${f#"$ROOTFS"}"
  else
    echo "removing ${f#"$ROOTFS"}"; rm -f "$f"
  fi
done < <(find "$ROOTFS/etc" "$ROOTFS/var" -xdev \( -name '*.old' -o -name '*.pacnew' -o -name '*.pacsave' \) -print0)

# Nothing machine- or owner-specific may ship (lab/overlay/privacy-scan.sh does the
# full string scan for releases). machine-id stays absent: systemd creates it at first boot.
privacy_leaks() {
  local r=$1 p
  for p in etc/machine-id var/lib/dbus/machine-id etc/hostname etc/pacman.d/gnupg; do
    [[ -e $r/$p ]] && echo "$p"
  done
  find "$r/root" "$r/home" "$r/var/log/journal" -mindepth 1 -maxdepth 1 2>/dev/null
  find "$r/etc/ssh" -name 'ssh_host_*key*' 2>/dev/null
  true
}
leaks=$(privacy_leaks "$ROOTFS")
[[ -z $leaks ]] || die "machine-specific files left in the image: $(paste -sd' ' <<<"$leaks")"

# --- 7. pack ------------------------------------------------------------------------------
name="Whyprland-${BUILD_DATE}.wsl"
unmount_rootfs
[[ -z $(rootfs_mounts) ]] || die "still mounted under $ROOTFS: $(rootfs_mounts | paste -sd' ')"
log "Packing $OUT/$name"
tar --numeric-owner --xattrs --xattrs-include='*' --acls --sort=name \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    -C "$ROOTFS" -c . |
  nice -n 10 xz -T0 -"$XZ_LEVEL" >"$OUT/$name.part"
mv -f "$OUT/$name.part" "$OUT/$name"
(cd "$OUT" && sha256sum "$name" >"$name.sha256")

du -sh --apparent-size "$ROOTFS" | awk '{print "rootfs: " $1}'
ls -la "$OUT/$name"
for p in "${REQUIRED_WOMARCHY[@]}"; do printf '%s ' "$(pacman -r "$ROOTFS" -Q "$p" 2>/dev/null || echo "$p:none")"; done; echo
(( ${KEEP_ROOTFS:-0} )) || remove_rootfs
echo "$OUT/$name"
