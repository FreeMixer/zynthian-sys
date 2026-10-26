#!/bin/bash
#******************************************************************************
# Start or stop the mod-host that MOD-UI talks to on port 5555.
#
#   mod-host-backend.sh start|stop|status
#
# ZYNTHIAN_MODHOST_BACKEND picks the backend:
#   plugin-hostd  plugin-hostd, one worker process per plugin (the default)
#   jack_load     mod-host as a JACK internal client
#
# The value comes from the environment if set, else from zynthian_envars.sh.
# plugin-hostd falls back to jack_load when plugin-hostd is not installed.
# Start removes the other backend first, so both never run. Stop removes
# whichever one is running, whatever the setting says now.
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}

PORT=5555
FEEDBACK_PORT=5556
PHD_CONF="$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf"
PHD_CONF_DEFAULT="$ZYNTHIAN_SYS_DIR/config/plugin-hostd.conf"
PHD_STATE=/run/plugin-hostd
READY_TIMEOUT=10

JACK_LOAD="${JACKD_BIN_PATH:+$JACKD_BIN_PATH/}jack_load"
JACK_UNLOAD="${JACKD_BIN_PATH:+$JACKD_BIN_PATH/}jack_unload"
JACK_LSP="${JACKD_BIN_PATH:+$JACKD_BIN_PATH/}jack_lsp"

get_backend() {
	local backend=$ZYNTHIAN_MODHOST_BACKEND
	if [ -z "$backend" ] && [ -f "$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh" ]; then
		backend=$(sed -n 's/^export ZYNTHIAN_MODHOST_BACKEND=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' \
			"$ZYNTHIAN_CONFIG_DIR/zynthian_envars.sh" | tail -n 1)
	fi
	backend=${backend:-plugin-hostd}
	# Without plugin-hostd installed, the only backend there is
	if [ "$backend" = plugin-hostd ] && ! command -v plugin-hostd >/dev/null; then
		backend=jack_load
	fi
	echo "$backend"
}

# PIDs of plugin-hostd daemons on our command port
phd_pids() {
	pgrep -f "^(/usr/bin/)?plugin-hostd .*-p $PORT( |$)"
}

internal_loaded() {
	"$JACK_LSP" 2>/dev/null | grep -q '^mod-host:'
}

listening() {
	ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

stop_phd() {
	local pids pid i
	pids=$(phd_pids)
	[ -n "$pids" ] || return 0
	echo "Stopping plugin-hostd ($(echo "$pids" | tr '\n' ' ' | sed 's/ $//'))"
	# SIGTERM stops every worker and then the daemon
	for pid in $pids; do kill -TERM "$pid" 2>/dev/null; done
	for ((i = 0; i < 50; i++)); do
		[ -z "$(phd_pids)" ] && return 0
		sleep 0.1
	done
	echo "plugin-hostd did not stop in 5 s, killing it"
	for pid in $(phd_pids); do kill -KILL "$pid" 2>/dev/null; done
}

stop_internal() {
	if internal_loaded; then
		echo "Unloading the mod-host JACK internal client"
		"$JACK_UNLOAD" mod-host >/dev/null
	fi
}

start_jack_load() {
	stop_phd
	if internal_loaded; then
		echo "mod-host is already loaded in JACK"
		return 0
	fi
	echo "Loading mod-host as a JACK internal client on port $PORT"
	"$JACK_LOAD" -i "$PORT" mod-host
}

start_plugin_hostd() {
	local pid i
	stop_internal
	if [ -n "$(phd_pids)" ]; then
		echo "plugin-hostd is already running on port $PORT"
		return 0
	fi
	if listening "$PORT"; then
		echo "Port $PORT is held by another program, not starting plugin-hostd" >&2
		return 1
	fi
	if [ ! -f "$PHD_CONF" ]; then
		echo "Installing $PHD_CONF from $PHD_CONF_DEFAULT"
		cp "$PHD_CONF_DEFAULT" "$PHD_CONF" || return 1
	fi
	mkdir -p "$PHD_STATE"
	echo "Starting plugin-hostd on ports $PORT and $FEEDBACK_PORT with $PHD_CONF"
	plugin-hostd -n -p "$PORT" -f "$FEEDBACK_PORT" -c "$PHD_CONF" &
	pid=$!
	# Ready once both ports accept, as plugin-hostd itself defines it
	for ((i = 0; i < READY_TIMEOUT * 10; i++)); do
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid"
			echo "plugin-hostd exited with code $? before it was ready" >&2
			return 1
		fi
		if listening "$PORT" && listening "$FEEDBACK_PORT"; then
			return 0
		fi
		sleep 0.1
	done
	echo "plugin-hostd was not ready in $READY_TIMEOUT s" >&2
	kill -TERM "$pid" 2>/dev/null
	return 1
}

case "$1" in
	start)
		backend=$(get_backend)
		case "$backend" in
			jack_load) start_jack_load ;;
			plugin-hostd) start_plugin_hostd ;;
			*)
				echo "Unknown ZYNTHIAN_MODHOST_BACKEND '$backend' (jack_load or plugin-hostd)" >&2
				exit 1
				;;
		esac
		;;
	stop)
		stop_internal
		stop_phd
		;;
	status)
		echo "setting: $(get_backend)"
		internal_loaded && echo "running: jack_load (mod-host JACK internal client)"
		pids=$(phd_pids)
		[ -n "$pids" ] && echo "running: plugin-hostd (pid $(echo "$pids" | tr '\n' ' ' | sed 's/ $//'))"
		exit 0
		;;
	*)
		echo "Usage: $0 start|stop|status" >&2
		exit 2
		;;
esac
