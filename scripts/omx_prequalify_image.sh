#!/bin/bash
#******************************************************************************
# Qualify every plugin of an assembled image once, so it ships qualified.
#
#   omx_prequalify_image.sh [--force]
#
# For image builders, after setup_system_raspioslite_64bit_*.sh and before the
# image is taken. It runs plugin-qualify-sync once, the way
# plugin-qualify-sync.service does, and writes what the services read:
# the pin file (/var/lib/omx/qualified.pins, plugin-hostd's pin_file), the
# qualification records, the descriptors and the sync's state. It packages
# nothing. The first boot of the image then finds every plugin recorded and
# only checks that none changed.
#
# It must run natively on arm64 (a Raspberry Pi), never under emulation or on
# another architecture: the records are keyed by the hashes of the plugin
# files, and a real-time safety and cost measured under emulation are not the
# device's. Without this step the image still works: the first boot after
# install qualifies the plugins at low priority, two minutes after boot.
#
# --force qualifies every plugin again, recorded or not.
#******************************************************************************

QUALIFY_CONF=${QUALIFY_CONF:-/etc/omx/qualify.conf}
CPUINFO=${CPUINFO:-/proc/cpuinfo}

args=(--system --config "$QUALIFY_CONF")
case "$1" in
	--force) args+=(--force) ;;
	"") ;;
	*) echo "Usage: $0 [--force]" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "Run it as root: it writes /var/lib/omx." >&2; exit 2; }
command -v plugin-qualify-sync >/dev/null || {
	echo "plugin-qualify-sync is not installed: run scripts/recipes/install_openmixer.sh first." >&2
	exit 2
}

# Native arm64 only. Under qemu-user, uname says aarch64 while /proc/cpuinfo
# is the host's, which has no ARM "CPU implementer" line.
if [ "$(dpkg --print-architecture)" != arm64 ] || [ "$(uname -m)" != aarch64 ] ||
	! grep -q '^CPU implementer' "$CPUINFO"; then
	echo "This must run natively on arm64 hardware: the qualification is keyed by the" >&2
	echo "hashes of the plugin files and measured on the CPU it runs on. Not run." >&2
	exit 2
fi

[ -f "$QUALIFY_CONF" ] || echo "note: $QUALIFY_CONF is missing, the sync's defaults apply"

echo "Qualifying the plugins of this image (plugin-qualify-sync ${args[*]}) ..."
start=$(date +%s)
# The same priority as the service: the build machine stays usable
nice -n 19 ionice -c 3 plugin-qualify-sync "${args[@]}" --hostd-port 0
rc=$?
echo "Took $(($(date +%s) - start)) s, exit $rc"
# What the services read, at the paths qualify.conf names
setting() {
	local v
	v=$(sed -n "s/^$1[[:space:]]\{1,\}//p" "$QUALIFY_CONF" 2>/dev/null | tail -n 1)
	echo "${v:-$2}"
}
for f in "$(setting pin_file /var/lib/omx/qualified.pins)" "$(setting state_file /var/lib/omx/qualify-sync.json)"; do
	[ -f "$f" ] && echo "  $f ($(wc -l <"$f") lines)"
done
for d in "$(setting qualification_dir /var/lib/omx/qualification)" "$(setting descriptor_dir /var/lib/omx/descriptors)"; do
	[ -d "$d" ] && echo "  $d ($(find "$d" -type f | wc -l) files)"
done
exit "$rc"
