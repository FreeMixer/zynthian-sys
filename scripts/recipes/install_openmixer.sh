#!/bin/bash
#******************************************************************************
# Install the OpenMixer apt repository and plugin-hostd with omx-clap-host,
# the program it runs CLAP plugins and its LV2 adapter in. Nothing is enabled:
# mod-host, MOD-UI and the UI's engines run as before.
#
# The repository comes from the openmixer-release package, which carries the
# signing key and one apt source per Debian release (bookworm, trixie).
# Running it again upgrades the packages to the newest version.
#******************************************************************************

RELEASE_URL="https://www.openmixer.org/deb/openmixer-release.deb"
PACKAGES="plugin-hostd omx-clap-host"

set -e

arch=$(dpkg --print-architecture)
case "$arch" in
	arm64|amd64) ;;
	*)
		echo "OpenMixer packages are built for arm64 and amd64, not $arch. Skipping."
		exit 0
		;;
esac

is_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

if ! is_installed openmixer-release; then
	echo "Adding the OpenMixer repository ..."
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	wget -q -O "$tmpdir/openmixer-release.deb" "$RELEASE_URL"
	apt-get -y install "$tmpdir/openmixer-release.deb"
fi

echo "Installing OpenMixer packages: $PACKAGES ..."
apt-get -y update
# shellcheck disable=SC2086
apt-get -y install $PACKAGES
