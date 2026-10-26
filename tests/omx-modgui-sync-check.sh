#!/bin/bash
#******************************************************************************
# Check scripts/omx-modgui-sync.sh on this machine, in directories of its own.
#
# Needs omx-panel, plugin-hostd (for plugin-hostd-probe), python3-lilv, one
# installed LV2 plugin with no MOD GUI (PLUGIN, default the swh amp of
# swh-lv2) and one with its own (OWN, default omx-drive of omx-plugins-lv2).
# MODUI_DIR, when it holds a built mod-ui, adds the check that mod-ui's own
# reader finds the generated GUI. Default /zynthian/zynthian-sw/mod-ui.
#
# It makes the plugin's descriptor as plugin-hostd does, then checks: one run
# writes the GUI; a second run changes nothing; a newer descriptor is picked
# up; a bundle without our marker is left byte for byte; one of ours for a
# plugin that is gone is removed; the plugin that ships a GUI is not touched.
#******************************************************************************

SYS_DIR=$(cd "$(dirname "$0")/.." && pwd)
SYNC="$SYS_DIR/scripts/omx-modgui-sync.sh"
PLUGIN=${PLUGIN:-http://plugin.org.uk/swh-plugins/amp}
OWN=${OWN:-urn:openmixer:drive}
MODUI_DIR=${MODUI_DIR:-/zynthian/zynthian-sw/mod-ui}
BASE_LV2_PATH=${LV2_PATH:-/usr/lib/lv2}

fails=0
checks=0
ok() { checks=$((checks + 1)); echo "ok   $*"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

for cmd in omx-panel plugin-hostd-probe python3; do
	command -v "$cmd" >/dev/null || { echo "missing: $cmd"; exit 2; }
done
python3 -c 'import lilv' 2>/dev/null || { echo "missing: python3-lilv"; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MODGUI_DIR="$work/modgui" STATE_DIR="$work/state" DESCRIPTOR_DIRS="$work/descriptors"
export ZYNTHIAN_CONFIG_DIR="$work/config" LV2_PATH="$BASE_LV2_PATH:$work/modgui"
mkdir -p "$DESCRIPTOR_DIRS" "$ZYNTHIAN_CONFIG_DIR"

# The bundle of a plugin and whether it has a MOD GUI, as lilv sees it
lv2_info() {
	python3 -I - "$1" <<'EOF'
import sys
from urllib.parse import unquote, urlparse
import lilv
w = lilv.World()
w.load_all()
p = w.get_all_plugins().get_by_uri(w.new_uri(sys.argv[1]))
if p is None:
    sys.exit(1)
res = w.new_uri("http://moddevices.com/ns/modgui#resourcesDirectory")
gui = w.new_uri("http://moddevices.com/ns/modgui#gui")
dirs = []
for g in p.get_value(gui):
    dirs.append(unquote(urlparse(str(w.get(g, res, None))).path))
print(unquote(urlparse(str(p.get_bundle_uri())).path).rstrip("/"), " ".join(dirs) or "-")
EOF
}

# What mod-ui's own reader gives as the GUI's resources directory
modui_resdir() {
	# mod-ui prints NOTICE lines on stdout too
	python3 -I - "$MODUI_DIR" "$1" <<'EOF' 2>/dev/null | sed -n 's/^resdir //p'
import sys
sys.path.insert(0, sys.argv[1])
from modtools.utils import init, get_plugin_gui
init()
print("resdir", get_plugin_gui(sys.argv[2]).get("resourcesDirectory") or "-", flush=True)
EOF
}

tree_sum() { (cd "$1" && find . -type f -printf '%p %T@\n' | sort && find . -type f -exec sha256sum {} + | sort); }
sync_run() { "$SYNC" --no-scan >"$work/run.log" 2>&1; local rc=$?; sed 's/^/   | /' "$work/run.log"; return $rc; }

read -r bundle dirs < <(lv2_info "$PLUGIN") || { echo "$PLUGIN is not installed"; exit 2; }
check "$PLUGIN is in $bundle and has no MOD GUI" test "$dirs" = -
read -r own_bundle own_dirs < <(lv2_info "$OWN") || { echo "$OWN is not installed"; exit 2; }
check "$OWN ships its MOD GUI in $own_bundle" test "$own_dirs" = "$own_bundle/modgui"
own_before=$(tree_sum "$own_bundle")
plugin_before=$(tree_sum "$bundle")

echo "-- descriptor, as plugin-hostd makes it on add"
desc="$DESCRIPTOR_DIRS/amp.json"
plugin-hostd-probe describe "lv2:$PLUGIN" >"$desc" 2>/dev/null
check "plugin-hostd-probe describe wrote $desc" test -s "$desc"
# Only this plugin has a descriptor, so the run is about it alone
echo "-- first run"
sync_run
check "first run exits 0" test $? = 0
out=$(find "$MODGUI_DIR" -mindepth 1 -maxdepth 1 -name '*.lv2' | head -n 1)
check "one bundle written: ${out#"$work"/}" test "$(find "$MODGUI_DIR" -mindepth 1 -maxdepth 1 | wc -l)" = 1
check "it holds manifest.ttl, modgui.ttl, modgui/ and the marker" \
	test -f "$out/manifest.ttl" -a -f "$out/modgui.ttl" -a -d "$out/modgui" -a -f "$out/.omx-modgui-sync"
panel_fresh() { (cd "$out" && omx-panel modgui --descriptor "$desc" --out "$out" --source "$desc" --check >/dev/null); }
check "omx-panel --check finds the generated files fresh" panel_fresh
read -r bundle_after dirs_after < <(lv2_info "$PLUGIN")
check "lilv: $PLUGIN keeps its bundle and gains the GUI" test "$bundle_after $dirs_after" = "$bundle $out/modgui"
if [ -f "$MODUI_DIR/modtools/utils.py" ]; then
	check "mod-ui reads the GUI from ${out#"$work"/}/modgui" test "$(modui_resdir "$PLUGIN")" = "$out/modgui"
else
	echo "skip mod-ui reader check: no mod-ui in $MODUI_DIR"
fi

echo "-- second run"
before=$(tree_sum "$MODGUI_DIR")
sync_run
check "second run exits 0" test $? = 0
check "second run writes nothing" grep -q '^omx-modgui-sync: 0 written, 1 up to date' "$work/run.log"
check "second run leaves every file and mtime as it was" test "$before" = "$(tree_sum "$MODGUI_DIR")"

echo "-- newer descriptor"
sleep 1
touch "$desc"
sync_run
check "a newer descriptor is picked up" grep -q '^omx-modgui-sync: 1 written' "$work/run.log"

echo "-- a bundle that is not ours"
rm "$out/.omx-modgui-sync"
echo "kept by hand" >>"$out/modgui.ttl"
touch "$desc"
before=$(tree_sum "$out")
sync_run
check "it is reported and skipped" grep -q "skip $PLUGIN: .* is not ours" "$work/run.log"
check "it is left byte for byte" test "$before" = "$(tree_sum "$out")"
rm -rf "$out"

echo "-- one of ours for a plugin that is gone"
mkdir -p "$MODGUI_DIR/gone.lv2"
printf 'urn:openmixer-test:gone\n--descriptor /nowhere\n' >"$MODGUI_DIR/gone.lv2/.omx-modgui-sync"
sync_run
check "it is removed" test ! -e "$MODGUI_DIR/gone.lv2"

echo "-- the plugins that ship a GUI"
check "no bundle written for $OWN" test -z "$(grep -lx "$OWN" "$MODGUI_DIR"/*.lv2/.omx-modgui-sync 2>/dev/null)"
check "$own_bundle is unchanged" test "$own_before" = "$(tree_sum "$own_bundle")"
check "$bundle is unchanged" test "$plugin_before" = "$(tree_sum "$bundle")"

echo "-- $((checks - fails))/$checks checks passed"
[ "$fails" = 0 ]
