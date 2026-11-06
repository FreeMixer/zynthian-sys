#!/bin/bash
#******************************************************************************
# Switch what runs as mod-host for MOD-UI and restart MOD-UI if it was running.
#
#   set_modhost_backend.sh jack_load|plugin-hostd
#
# Without an argument it prints the current setting and what is running.
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}
BACKEND_SH="$ZYNTHIAN_SYS_DIR/sbin/mod-host-backend.sh"

if [ -z "$1" ]; then
	"$BACKEND_SH" status
	exit 0
fi

backend=$1
case "$backend" in
	jack_load) ;;
	plugin-hostd)
		if ! command -v plugin-hostd >/dev/null; then
			echo "plugin-hostd is not installed. Run $ZYNTHIAN_SYS_DIR/scripts/recipes/install_openmixer.sh first." >&2
			exit 1
		fi
		;;
	*)
		echo "Usage: $0 jack_load|plugin-hostd" >&2
		exit 2
		;;
esac

old=$(unset ZYNTHIAN_MODHOST_BACKEND; "$BACKEND_SH" status | sed -n 's/^setting: //p')
modui_active=0
systemctl -q is-active mod-ui && modui_active=1

echo "mod-host backend: $old -> $backend"
if [ "$modui_active" = 1 ]; then
	echo "Stopping mod-ui"
	systemctl stop mod-ui
fi
echo "Stopping mod-host"
systemctl stop mod-host

echo "Writing ZYNTHIAN_MODHOST_BACKEND=\"$backend\" to $ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh"
"$ZYNTHIAN_SYS_DIR/sbin/set_envar.py" ZYNTHIAN_MODHOST_BACKEND "$backend" || exit 1

if [ "$modui_active" = 1 ]; then
	echo "Starting mod-ui, which starts mod-host"
	systemctl start mod-ui || exit 1
else
	echo "mod-ui was not running; the next start of the MOD-UI engine uses $backend"
fi

unset ZYNTHIAN_MODHOST_BACKEND
"$BACKEND_SH" status
echo "mod-host: $(systemctl is-active mod-host), mod-ui: $(systemctl is-active mod-ui)"
