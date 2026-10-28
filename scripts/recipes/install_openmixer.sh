#!/bin/bash
#******************************************************************************
# Install OpenMixer's plugin hosting on this Zynthian:
#
#   install_openmixer.sh [--upgrade]
#
# - the OpenMixer apt repository (package openmixer-release, which carries the
#   signing key and one apt source per Debian release);
# - plugin-hostd, omx-clap-host and plugin-qualify;
# - plugin-hostd as the engine the UI menus offer LV2 plugins through
#   (ZYNTHIAN_PLUGIN_ENGINE), in a config made before that default;
# - /zynthian/config/plugin-hostd.conf with the pins of the qualification sync;
# - the qualification sync (plugin-qualify-sync.timer and .path) with
#   Zynthian's plugin directories in /etc/omx/qualify.conf.
#
# Each of these is done once: the steps done are listed in
# $ZYNTHIAN_CONFIG_DIR/openmixer-defaults, so a later run leaves a setting
# changed by hand as it is. --upgrade also upgrades the packages. No service
# is started, stopped or restarted: the last lines say what applies when.
#******************************************************************************

RELEASE_URL="https://www.openmixer.org/deb/openmixer-release.deb"
PACKAGES="plugin-hostd omx-clap-host plugin-qualify"

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
DONE_FILE="$ZYNTHIAN_CONFIG_DIR/openmixer-defaults"
ENVARS="$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh"
PHD_CONF="$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf"
QUALIFY_CONF=${QUALIFY_CONF:-/etc/omx/qualify.conf}
SYSTEMD_UNIT_DIR=${SYSTEMD_UNIT_DIR:-/usr/lib/systemd/system}
SYNC_UNITS="plugin-qualify-sync.timer plugin-qualify-sync.path"
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

upgrade=0
case "$1" in
	--upgrade) upgrade=1 ;;
	"") ;;
	*) echo "Usage: $0 [--upgrade]" >&2; exit 2 ;;
esac

arch=$(dpkg --print-architecture)
case "$arch" in
	arm64) multiarch=aarch64-linux-gnu ;;
	amd64) multiarch=x86_64-linux-gnu ;;
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
# The installed version, empty when not installed (a removed package keeps its
# version in dpkg's database until it is purged)
version_of() {
	is_installed "$1" && dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

is_done() { grep -qx "$1" "$DONE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >>"$DONE_FILE"; }

# The value of an exported variable in zynthian_envars.sh, quotes removed
envar_get() {
	sed -n "s/^export $1=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$ENVARS" | tail -n 1
}
envar_set() {
	if grep -q "^export $1=" "$ENVARS"; then
		sed -i "s/^export $1=.*/export $1=\"$2\"/" "$ENVARS"
	else
		echo "export $1=\"$2\"" >>"$ENVARS"
	fi
}

# The value of a key in a "key value" file, the last line winning
conf_get() {
	sed -n "s/^$2[[:space:]]\{1,\}//p" "$1" | tail -n 1
}
conf_set() {
	if grep -q "^$2[[:space:]]" "$1"; then
		sed -i "s|^$2[[:space:]].*|$2 $3|" "$1"
	else
		printf '%s %s\n' "$2" "$3" >>"$1"
	fi
}

#------------------------------------------------------------------------------
# Repository and packages
#------------------------------------------------------------------------------

if ! is_installed openmixer-release; then
	echo "Adding the OpenMixer repository ..."
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	if wget -q -O "$tmpdir/openmixer-release.deb" "$RELEASE_URL" &&
		apt-get "${APT_OPTS[@]}" install "$tmpdir/openmixer-release.deb"; then
		change "added the OpenMixer repository (openmixer-release)"
	else
		note "could not add the OpenMixer repository: the next run tries again"
		failed=1
	fi
fi

# A package is installed once: one removed by hand afterwards stays removed
# (--upgrade installs it again). A package a later version of this recipe
# adds is installed on its first run.
missing=""
for p in $PACKAGES; do
	if is_installed "$p"; then
		mark_done "package $p"
	elif ! is_done "package $p"; then
		missing="$missing $p"
	fi
done
missing=${missing# }

if [ "$failed" = 0 ] && { [ "$upgrade" = 1 ] || [ -n "$missing" ]; }; then
	declare -A before
	for p in $PACKAGES; do before[$p]=$(version_of "$p"); done
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
			is_installed "$p" && mark_done "package $p"
		done
	else
		note "the OpenMixer packages did not install: the next run tries again"
		failed=1
	fi
fi

#------------------------------------------------------------------------------
# Zynthian settings
#------------------------------------------------------------------------------

mkdir -p "$ZYNTHIAN_CONFIG_DIR"

# ZYNTHIAN_PLUGIN_ENGINE, for a config made before zynthian_envars.sh carried
# it; one that names an engine is left as it is. Without the file (a new
# image) update_zynthian_sys.sh copies the defaults and runs this again.
engine_changed=0
if ! is_done envars && [ -f "$ENVARS" ] && command -v plugin-hostd >/dev/null; then
	if [ -z "$(envar_get ZYNTHIAN_PLUGIN_ENGINE)" ]; then
		envar_set ZYNTHIAN_PLUGIN_ENGINE plugin-hostd
		change "ZYNTHIAN_PLUGIN_ENGINE unset -> plugin-hostd in $ENVARS"
		engine_changed=1
	fi
	mark_done envars
fi

# plugin-hostd.conf: pins required, from the sync's pin file
phd_changed=0
if ! is_done hostd-conf && command -v plugin-hostd >/dev/null; then
	if [ ! -f "$PHD_CONF" ]; then
		cp "$ZYNTHIAN_SYS_DIR/config/plugin-hostd.conf" "$PHD_CONF"
		change "wrote $PHD_CONF"
		phd_changed=1
	else
		for kv in "require_pins 1" "pin_mode first-use" "pin_file /var/lib/omx/qualified.pins" \
			"qualification_dir /var/lib/omx/qualification" "descriptor_dir /var/lib/omx/descriptors"; do
			key=${kv%% *}
			value=${kv#* }
			old=$(conf_get "$PHD_CONF" "$key")
			if [ "$old" != "$value" ]; then
				conf_set "$PHD_CONF" "$key" "$value"
				change "$key ${old:-unset} -> $value in $PHD_CONF"
				phd_changed=1
			fi
		done
	fi
	mark_done hostd-conf
fi

# The pin file must exist for plugin-hostd to start: empty until the first sync.
# Not a step done once: it is put back at every boot and every run.
TMPFILES_CONF=/etc/tmpfiles.d/omx-qualified-pins.conf
if command -v plugin-hostd >/dev/null; then
	if ! cmp -s "$ZYNTHIAN_SYS_DIR/etc/tmpfiles.d/omx-qualified-pins.conf" "$TMPFILES_CONF"; then
		mkdir -p /etc/tmpfiles.d
		cp "$ZYNTHIAN_SYS_DIR/etc/tmpfiles.d/omx-qualified-pins.conf" "$TMPFILES_CONF"
		change "wrote $TMPFILES_CONF"
	fi
	if [ ! -e /var/lib/omx/qualified.pins ]; then
		systemd-tmpfiles --create "$TMPFILES_CONF"
		change "created an empty /var/lib/omx/qualified.pins"
	fi
fi

# qualify.conf: Zynthian's directories, unless the file already holds settings
if ! is_done qualify-conf && is_installed plugin-qualify; then
	rendered=$(sed "s/#MULTIARCH#/$multiarch/g" "$ZYNTHIAN_SYS_DIR/config/qualify.conf")
	if [ -f "$QUALIFY_CONF" ] && [ "$(cat "$QUALIFY_CONF")" = "$rendered" ]; then
		:
	elif [ -f "$QUALIFY_CONF" ] && grep -q '^[[:space:]]*[^#[:space:]]' "$QUALIFY_CONF"; then
		note "$QUALIFY_CONF holds settings of its own: left as it is"
	else
		mkdir -p "$(dirname "$QUALIFY_CONF")"
		echo "$rendered" >"$QUALIFY_CONF"
		change "wrote Zynthian's plugin directories to $QUALIFY_CONF"
	fi
	mark_done qualify-conf
fi

# The sync's units: enabled, not started. The timer's first run is two
# minutes after the next boot; the path unit runs it when a plugin is installed.
if ! is_done qualify-sync && is_installed plugin-qualify; then
	if [ -f "$SYSTEMD_UNIT_DIR/plugin-qualify-sync.timer" ]; then
		for u in $SYNC_UNITS; do
			if [ "$(systemctl is-enabled "$u" 2>/dev/null)" != enabled ]; then
				if systemctl enable "$u" >/dev/null 2>&1; then
					change "enabled $u"
				else
					note "could not enable $u"
					failed=1
				fi
			fi
		done
		[ "$failed" = 0 ] && mark_done qualify-sync
	else
		note "plugin-qualify $(version_of plugin-qualify) has no qualification sync yet: the next run after an upgrade enables it"
	fi
fi

#------------------------------------------------------------------------------
# Report
#------------------------------------------------------------------------------

if [ ${#changes[@]} = 0 ]; then
	echo "OpenMixer defaults: nothing to change"
else
	echo "OpenMixer defaults: ${#changes[@]} changed"
	for c in "${changes[@]}"; do echo "  $c"; done
fi
for n in "${notes[@]}"; do echo "  note: $n"; done
if [ "$phd_changed" = 1 ]; then
	echo "  plugin-hostd was not restarted: the change applies at its next start"
fi
if [ "$engine_changed" = 1 ]; then
	echo "  zynthian was not restarted: the menus offer plugin-hostd from its next start"
fi
exit "$failed"
