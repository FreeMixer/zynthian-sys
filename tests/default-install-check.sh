#!/bin/bash
#******************************************************************************
# Check what install_openmixer.sh sets up: packages, repository, envars, the
# qualification sync's units, plugin-hostd's pin keys and LV2_PATH, after the
# update path of an existing Zynthian and after a new image's setup, and that
# running the update again changes nothing.
#
# Container only: it rewrites /zynthian/config, /etc/omx and /etc/systemd.
# Needs debian:trixie (amd64 is fine) with openmixer-release, plugin-hostd,
# omx-clap-host and plugin-qualify installed, omx-plugins for the one CLAP the
# image hook qualifies, and this tree copied to /zynthian/zynthian-sys:
#
#   podman run --rm -v $PWD:/src:ro <image> bash -c \
#     'cp -a /src /zynthian/zynthian-sys && /zynthian/zynthian-sys/tests/default-install-check.sh'
#******************************************************************************

SYS_DIR=/zynthian/zynthian-sys
CONFIG_DIR=/zynthian/config
ENVARS="$CONFIG_DIR/zynthian_envars.sh"
PHD_CONF="$CONFIG_DIR/plugin-hostd.conf"
QUALIFY_CONF=/etc/omx/qualify.conf
PACKAGES="openmixer-release plugin-hostd omx-clap-host plugin-qualify"
FIXTURE_PACKAGES="omx-plugins"
PIANOTEQ_DIR=/zynthian/zynthian-sw/pianoteq/arm-64bit

fails=0
checks=0
ok() { checks=$((checks + 1)); echo "ok   $*"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

[ -f /run/.containerenv ] || [ -f /.dockerenv ] || [ -n "$OMX_CHECK_IN_CONTAINER" ] ||
	{ echo "container only: it rewrites /zynthian/config and /etc"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run it as root"; exit 2; }
[ -x "$SYS_DIR/scripts/update_zynthian_sys.sh" ] || { echo "copy this tree to $SYS_DIR"; exit 2; }
for p in $PACKAGES $FIXTURE_PACKAGES; do
	dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || { echo "missing package: $p"; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The package's qualify.conf sets nothing: every line a comment
sed 's/^\([[:space:]]*[^#[:space:]]\)/#\1/' "$QUALIFY_CONF" >"$work/qualify.conf.package"
mkdir -p /zynthian/zynthian-my-data /zynthian/zynthian-data /zynthian/zynthian-ui /zynthian/zynthian-plugins/lv2

# shellcheck disable=SC1090
envar() { (set +u; . "$1" >/dev/null 2>&1; eval "echo \"\${$2}\""); }
conf() { sed -n "s/^$2[[:space:]]\{1,\}//p" "$1" | tail -n 1; }
dirs_of() { tr ':' '\n' | sed -e 's|//*|/|g' -e 's|/$||' | awk 'NF && !seen[$0]++'; }
update() {
	(cd "$SYS_DIR/scripts" && ZYNTHIAN_SYS_DIR=$SYS_DIR ./update_zynthian_sys.sh) >"$work/update.log" 2>&1
	sed -n '/^OpenMixer defaults/,$p' "$work/update.log" | sed 's/^/   | /'
}
state_sum() {
	sha256sum "$ENVARS" "$PHD_CONF" "$QUALIFY_CONF" "$CONFIG_DIR/openmixer-defaults" \
		/etc/tmpfiles.d/omx-qualified-pins.conf /var/lib/omx/qualified.pins \
		/etc/systemd/system/mod-host.service /etc/systemd/system/plugin-qualify-sync.*.d/* 2>&1
	for u in plugin-qualify-sync.timer plugin-qualify-sync.path; do
		echo "$u $(systemctl is-enabled "$u" 2>&1)"
	done
}

# Every item of the default install
assert_defaults() {
	local p d
	for p in $PACKAGES; do
		check "package $p is installed" dpkg-query -W "$p"
	done
	check "an apt source names the OpenMixer repository" \
		grep -Rqs 'openmixer.org/deb' /etc/apt/sources.list.d/

	check "plugin-qualify-sync.timer is enabled" test "$(systemctl is-enabled plugin-qualify-sync.timer)" = enabled
	check "plugin-qualify-sync.path is enabled" test "$(systemctl is-enabled plugin-qualify-sync.path)" = enabled
	check "the path unit also watches Pianoteq and the user's plugins" \
		grep -qx "PathChanged=$PIANOTEQ_DIR" /etc/systemd/system/plugin-qualify-sync.path.d/zynthian.conf

	# qualify.conf: Zynthian's directories, and plugin-qualify-sync reads it
	local qdirs
	qdirs=$( (conf "$QUALIFY_CONF" lv2_path; echo; conf "$QUALIFY_CONF" lv2_extra) | tr '\n' ':' | dirs_of)
	for d in /usr/lib/lv2 /usr/local/lib/lv2 /zynthian/zynthian-plugins/lv2 /zynthian/zynthian-my-data/plugins \
		/zynthian/zynthian-my-data/plugins/lv2 "$PIANOTEQ_DIR"; do
		check "qualify.conf lists $d" grep -qx "$d" <<<"$qdirs"
	done
	mkdir -p "$work/empty"
	check "plugin-qualify-sync takes qualify.conf" plugin-qualify-sync --system --config "$QUALIFY_CONF" \
		--lv2-path "$work/empty" --lv2-extra "" --clap-path "$work/empty" --pin-file "$work/p.pins" \
		--state-file "$work/s.json" --qualification-dir "$work/q" --descriptor-dir "$work/d" --hostd-port 0

	# plugin-hostd.conf: pins required, first-use for what is not qualified yet, the sync's pin file
	check "plugin-hostd.conf: require_pins 1" test "$(conf "$PHD_CONF" require_pins)" = 1
	check "plugin-hostd.conf: pin_mode first-use" test "$(conf "$PHD_CONF" pin_mode)" = first-use
	check "plugin-hostd.conf: pin_file is the sync's ($(conf "$QUALIFY_CONF" pin_file))" \
		test -n "$(conf "$PHD_CONF" pin_file)" -a "$(conf "$PHD_CONF" pin_file)" = "$(conf "$QUALIFY_CONF" pin_file)"
	check "plugin-hostd.conf: qualification_dir is the sync's" \
		test "$(conf "$PHD_CONF" qualification_dir)" = "$(conf "$QUALIFY_CONF" qualification_dir)"
	check "plugin-hostd.conf: descriptor_dir is the sync's" \
		test "$(conf "$PHD_CONF" descriptor_dir)" = "$(conf "$QUALIFY_CONF" descriptor_dir)"
	check "the pin file is there before the first sync" test -f "$(conf "$PHD_CONF" pin_file)"
	check "plugin-hostd starts with it before the first sync" phd_starts
	rm -f "$(conf "$PHD_CONF" pin_file)"
	systemd-tmpfiles --create /etc/tmpfiles.d/omx-qualified-pins.conf 2>/dev/null
	check "a boot puts a deleted pin file back (tmpfiles.d)" test -f "$(conf "$PHD_CONF" pin_file)"

	# envars, in the config and in the defaults a new config is made from
	check "config: ZYNTHIAN_PLUGIN_ENGINE=plugin-hostd" test "$(envar "$ENVARS" ZYNTHIAN_PLUGIN_ENGINE)" = plugin-hostd
	check "defaults: ZYNTHIAN_PLUGIN_ENGINE=plugin-hostd" \
		test "$(envar "$SYS_DIR/scripts/zynthian_envars.sh" ZYNTHIAN_PLUGIN_ENGINE)" = plugin-hostd
	check "defaults: ZYNTHIAN_PLUGIN_HOSTD_PORT is declared, next to ZYNTHIAN_MODHOST_BACKEND" \
		test "$(envar "$SYS_DIR/scripts/zynthian_envars.sh" ZYNTHIAN_PLUGIN_HOSTD_PORT)" = 5570
	check "defaults: MOD-UI keeps jack_load" \
		test "$(envar "$SYS_DIR/scripts/zynthian_envars.sh" ZYNTHIAN_MODHOST_BACKEND)" = jack_load

	# LV2_PATH: what MOD-UI's plugin-hostd searches, and the sync searches it in the same order
	local lv2 unit
	lv2=$(envar "$ENVARS" LV2_PATH | dirs_of)
	unit=$(sed -n 's/^Environment=LV2_PATH=//p' /etc/systemd/system/mod-host.service | dirs_of)
	for d in /usr/lib/lv2 /usr/local/lib/lv2 /zynthian/zynthian-plugins/lv2 /zynthian/zynthian-my-data/plugins/lv2; do
		check "LV2_PATH has $d" grep -qx "$d" <<<"$lv2"
	done
	check "mod-host.service runs with the same LV2_PATH" test "$unit" = "$lv2"
	check "the sync searches LV2_PATH's plugin directories in LV2_PATH's order" \
		in_order "$(grep -v -E 'presets|modgui' <<<"$lv2")" "$qdirs"
	check "the Pianoteq recipe links its bundles into a directory on LV2_PATH" \
		grep -q 'ln -s $ZYNTHIAN_SW_DIR/pianoteq/$armdir/\*.lv2 $ZYNTHIAN_PLUGINS_DIR/lv2' \
		"$SYS_DIR/scripts/recipes/install_pianoteq_binary.sh"
}

# The lines of $1 appear in $2 in the same order
in_order() {
	awk 'BEGIN { n = 0; i = 0 } NR == FNR { want[n++] = $0; next } i < n && $0 == want[i] { i++ } END { exit (i < n) }' \
		<(echo "$1") <(echo "$2")
}

phd_starts() {
	local pid i rc=1
	plugin-hostd -n -p 5590 -f 5591 -c "$PHD_CONF" >"$work/phd.log" 2>&1 &
	pid=$!
	for ((i = 0; i < 50; i++)); do
		if ss -Hltn 'sport = :5590' | grep -q .; then rc=0; break; fi
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -TERM "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	[ "$rc" = 0 ] || sed 's/^/   | /' "$work/phd.log"
	return "$rc"
}

assert_idempotent() {
	local before
	before=$(state_sum)
	echo "-- update again"
	update
	check "the second update reports nothing to change" grep -qx 'OpenMixer defaults: nothing to change' "$work/update.log"
	check "the second update leaves every file and unit as it was" test "$before" = "$(state_sum)"
}

reset() {
	rm -rf "$CONFIG_DIR"
	mkdir -p "$CONFIG_DIR"
	cp "$work/qualify.conf.package" "$QUALIFY_CONF"
	rm -rf /etc/systemd/system/plugin-qualify-sync.path.d /etc/systemd/system/plugin-qualify-sync.service.d \
		/etc/tmpfiles.d/omx-qualified-pins.conf /var/lib/omx/qualified.pins
	systemctl disable plugin-qualify-sync.timer plugin-qualify-sync.path >/dev/null 2>&1
}

echo "== an existing Zynthian: no ZYNTHIAN_PLUGIN_ENGINE, require_pins 0, the sync disabled"
reset
# The envars of a config made before this change
sed '/ZYNTHIAN_PLUGIN_ENGINE/d' "$SYS_DIR/scripts/zynthian_envars.sh" >"$ENVARS"
check "before: ZYNTHIAN_PLUGIN_ENGINE unset" test -z "$(envar "$ENVARS" ZYNTHIAN_PLUGIN_ENGINE)"
# The plugin-hostd.conf the mod-host backend copied before this change
printf 'mod_host /usr/local/bin/mod-host\nclap_host omx-clap-host\nlv2_worker auto\nrequire_pins 0\nstate_root /run/plugin-hostd\ndescriptor_dir /var/lib/omx/descriptors\n' >"$PHD_CONF"
echo "-- update"
update
check "the update says plugin-hostd was not restarted" grep -q 'plugin-hostd was not restarted' "$work/update.log"
check "the update says the menus change at zynthian's next start" grep -q 'menus offer plugin-hostd from its next start' "$work/update.log"
assert_defaults
assert_idempotent
echo "-- a choice made after the update stays"
sed -i 's/^require_pins .*/require_pins 0/' "$PHD_CONF"
sed -i 's/^export ZYNTHIAN_PLUGIN_ENGINE=.*/export ZYNTHIAN_PLUGIN_ENGINE="jalv"/' "$ENVARS"
systemctl disable plugin-qualify-sync.timer >/dev/null 2>&1
update
check "require_pins 0 set by hand is kept" test "$(conf "$PHD_CONF" require_pins)" = 0
check "ZYNTHIAN_PLUGIN_ENGINE=jalv set by hand is kept" test "$(envar "$ENVARS" ZYNTHIAN_PLUGIN_ENGINE)" = jalv
check "the timer disabled by hand stays disabled" test "$(systemctl is-enabled plugin-qualify-sync.timer)" = disabled
echo "-- a package removed by hand stays removed"
apt-get -qq remove -y plugin-qualify >/dev/null 2>&1
update
check "plugin-qualify removed by hand is not installed again" \
	test -z "$(dpkg-query -W -f='${Status}' plugin-qualify 2>/dev/null | grep 'ok installed')"

recipe() {
	(cd "$SYS_DIR/scripts" && ZYNTHIAN_SYS_DIR=$SYS_DIR ZYNTHIAN_CONFIG_DIR=$CONFIG_DIR recipes/install_openmixer.sh) \
		>"$work/recipe.log" 2>&1
	sed -n '/^OpenMixer defaults/,$p' "$work/recipe.log" | sed 's/^/   | /'
}

echo "== a plugin-qualify with no sync yet, then one with it"
reset
cp "$SYS_DIR/scripts/zynthian_envars.sh" "$ENVARS"
mkdir -p "$work/no-units"
SYSTEMD_UNIT_DIR=$work/no-units recipe
check "the recipe says the sync is not there yet" grep -q 'has no qualification sync yet' "$work/recipe.log"
check "and does not mark it done" test "$(grep -cx qualify-sync "$CONFIG_DIR/openmixer-defaults")" = 0
recipe
check "the next run enables the timer" test "$(systemctl is-enabled plugin-qualify-sync.timer)" = enabled

echo "== a new image: the recipe of the setup script, then update_zynthian_sys.sh"
reset
# One package the recipe installs from the repository (removed above, or here)
apt-get -qq remove -y plugin-qualify >/dev/null 2>&1
check "before: plugin-qualify is not installed" test -z "$(dpkg-query -W -f='${Status}' plugin-qualify 2>/dev/null | grep 'ok installed')"
recipe
check "the recipe installed plugin-qualify from the repository" grep -q '^  installed plugin-qualify ' "$work/recipe.log"
update
assert_defaults
assert_idempotent

echo "== the image hook, scripts/omx_prequalify_image.sh"
HOOK="$SYS_DIR/scripts/omx_prequalify_image.sh"
before=$(sha256sum /var/lib/omx/qualified.pins)
"$HOOK" >"$work/hook.log" 2>&1
rc=$?
sed 's/^/   | /' "$work/hook.log"
check "it refuses to run on $(dpkg --print-architecture) (exit 2)" test "$rc" = 2
check "and writes nothing" test "$before" = "$(sha256sum /var/lib/omx/qualified.pins)"
# The arm64 path, with the architecture probes stubbed, over one CLAP
mkdir -p "$work/arm/bin" "$work/arm/clap" "$work/arm/lv2"
printf '#!/bin/sh\necho arm64\n' >"$work/arm/bin/dpkg"
printf '#!/bin/sh\necho aarch64\n' >"$work/arm/bin/uname"
chmod +x "$work/arm/bin/dpkg" "$work/arm/bin/uname"
printf 'processor\t: 0\nCPU implementer\t: 0x41\n' >"$work/arm/cpuinfo"
cp /usr/lib/clap/omx-drive.clap "$work/arm/clap/"
printf '%s\n' "clap_path $work/arm/clap" "lv2_path $work/arm/lv2" "lv2_extra" "pin_file $work/arm/qualified.pins" \
	"qualification_dir $work/arm/qualification" "descriptor_dir $work/arm/descriptors" \
	"state_file $work/arm/qualify-sync.json" >"$work/arm/qualify.conf"
PATH="$work/arm/bin:$PATH" CPUINFO="$work/arm/cpuinfo" QUALIFY_CONF="$work/arm/qualify.conf" "$HOOK" >"$work/hook.log" 2>&1
rc=$?
sed 's/^/   | /' "$work/hook.log"
check "on arm64 it runs the sync (exit 0)" test "$rc" = 0
check "it writes the pin of the CLAP to the pin file" grep -q 'omx-drive.clap' "$work/arm/qualified.pins"
check "it writes a qualification record" test -n "$(find "$work/arm/qualification" -type f)"
check "it writes the sync's state" test -s "$work/arm/qualify-sync.json"
plugin-qualify-sync --system --config "$work/arm/qualify.conf" --hostd-port 0 >"$work/boot.log" 2>&1
check "the first boot's sync then qualifies nothing again" grep -q '^qualified 0, skipped 1,' "$work/boot.log"

echo "-- $((checks - fails))/$checks checks passed"
[ "$fails" = 0 ]
