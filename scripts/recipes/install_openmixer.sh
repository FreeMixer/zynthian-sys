#!/bin/bash
#******************************************************************************
# Install the OpenMixer packages on this Zynthian:
#
#   install_openmixer.sh [--upgrade]
#
# - the OpenMixer apt repository (package openmixer-release, which carries the
#   signing key and one apt source per Debian release);
# - plugin-hostd, omx-clap-host (with omx-clap-scan), omx-plugins, omx-panel
#   and plugin-qualify.
#
# It does not make plugin-hostd the mod-host of MOD-UI nor the UI's plugin
# engine: ZYNTHIAN_MODHOST_BACKEND and ZYNTHIAN_PLUGIN_ENGINE choose that.
# The packages are installed once (the steps done are listed in
# $ZYNTHIAN_CONFIG_DIR/openmixer-defaults); --upgrade also upgrades them. No
# service is started, stopped or restarted.
#******************************************************************************

PACKAGES="plugin-hostd omx-clap-host omx-plugins omx-panel plugin-qualify"

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
DONE_FILE="$ZYNTHIAN_CONFIG_DIR/openmixer-defaults"
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

upgrade=0
case "$1" in
	--upgrade) upgrade=1 ;;
	"") ;;
	*) echo "Usage: $0 [--upgrade]" >&2; exit 2 ;;
esac

arch=$(dpkg --print-architecture)
case "$arch" in
	arm64 | amd64) ;;
	*)
		echo "OpenMixer packages are built for arm64 and amd64, not $arch. Skipping."
		exit 0
		;;
esac

changes=()
notes=()
failed=0
change() { changes+=("$1"); }
note() { notes+=("$1"); }

is_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}
version_of() {
	dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

is_done() { grep -qx "$1" "$DONE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >>"$DONE_FILE"; }

mkdir -p "$ZYNTHIAN_CONFIG_DIR"

#------------------------------------------------------------------------------
# Repository and packages
#------------------------------------------------------------------------------

if ! is_installed openmixer-release; then
	echo "Adding the OpenMixer repository ..."
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	# the package the channel's signed index lists, checked against the archive
	# key pinned in this checkout: apt does not check a local .deb
	if "$ZYNTHIAN_SYS_DIR/scripts/omx-fetch-release.sh" "$tmpdir/openmixer-release.deb" &&
		apt-get "${APT_OPTS[@]}" install "$tmpdir/openmixer-release.deb"; then
		change "added the OpenMixer repository (openmixer-release)"
	else
		note "could not add the OpenMixer repository: the next run tries again"
		failed=1
	fi
fi

missing=""
for p in $PACKAGES; do
	is_installed "$p" || missing="$missing $p"
done
missing=${missing# }

if [ "$failed" = 0 ] && { [ "$upgrade" = 1 ] || { [ -n "$missing" ] && ! is_done packages; }; }; then
	declare -A before
	for p in $PACKAGES; do before[$p]=$(is_installed "$p" && version_of "$p"); done
	# --upgrade takes them all to the newest; otherwise only the missing ones are installed
	todo=$missing
	[ "$upgrade" = 1 ] && todo=$PACKAGES
	echo "Installing OpenMixer packages: $todo ..."
	# shellcheck disable=SC2086
	if apt-get -y update && apt-get "${APT_OPTS[@]}" install $todo; then
		for p in $PACKAGES; do
			now=$(version_of "$p")
			if [ -z "${before[$p]}" ]; then
				change "installed $p $now"
			elif [ "${before[$p]}" != "$now" ]; then
				change "upgraded $p ${before[$p]} -> $now"
			fi
		done
		mark_done packages
	else
		note "the OpenMixer packages did not install: the next run tries again"
		failed=1
	fi
elif [ -z "$missing" ]; then
	mark_done packages
fi
if is_installed omx-clap-host && ! command -v omx-clap-scan >/dev/null; then
	note "omx-clap-scan is missing from omx-clap-host $(version_of omx-clap-host)"
fi

#------------------------------------------------------------------------------
# Report
#------------------------------------------------------------------------------

if [ ${#changes[@]} = 0 ]; then
	echo "OpenMixer: nothing to change"
else
	echo "OpenMixer: ${#changes[@]} changed"
	for c in "${changes[@]}"; do echo "  $c"; done
fi
for n in "${notes[@]}"; do echo "  note: $n"; done
exit "$failed"
