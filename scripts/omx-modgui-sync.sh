#!/bin/bash
#******************************************************************************
# Give a MOD GUI to every installed LV2 plugin that ships none, made by
# omx-panel from the plugin's descriptor, so MOD-UI shows a panel for each.
#
#   omx-modgui-sync.sh [--dry-run] [--no-scan]
#
# For each plugin on LV2_PATH with no MOD GUI anywhere, it writes a bundle in
# MODGUI_DIR (default $ZYNTHIAN_MY_DATA_DIR/modgui, which is on LV2_PATH):
# modgui.ttl and modgui/ from `omx-panel modgui`, and a manifest.ttl holding
# the same triples, so lilv adds the GUI to the installed plugin. The
# plugin's own bundle is never touched.
#
# The descriptor is, in this order: the plugin's declaration in omx-contract
# (`omx-panel descriptors --installed`, then `omx-panel modgui --installed <package>/<name>`; our own plugins), the
# newest one in DESCRIPTOR_DIRS (written by plugin-hostd and plugin-qualify),
# or, unless --no-scan, one made here by `plugin-hostd-probe describe`.
#
# A bundle newer than its descriptor is left as it is. A bundle without our
# marker file is never written or removed. One of ours goes away when its
# plugin is uninstalled or ships a MOD GUI of its own.
#******************************************************************************

ZYNTHIAN_MY_DATA_DIR=${ZYNTHIAN_MY_DATA_DIR:-/zynthian/zynthian-my-data}
ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
MODGUI_DIR=${MODGUI_DIR:-$ZYNTHIAN_MY_DATA_DIR/modgui}
DESCRIPTOR_DIRS=${DESCRIPTOR_DIRS:-/var/lib/omx/descriptors}
# Our scans and work files. Not under MODGUI_DIR: lilv reads every directory
# there as a bundle.
STATE_DIR=${STATE_DIR:-/var/lib/omx/modgui-sync}
SCAN_DIR="$STATE_DIR/descriptors"
MARKER=.omx-modgui-sync
SCAN_TIMEOUT=30

dry_run=0
scan=1
for arg in "$@"; do
	case "$arg" in
		--dry-run) dry_run=1 ;;
		--no-scan) scan=0 ;;
		*) echo "Usage: $0 [--dry-run] [--no-scan]" >&2; exit 2 ;;
	esac
done

for cmd in omx-panel python3; do
	command -v "$cmd" >/dev/null || { echo "omx-modgui-sync: $cmd is not installed" >&2; exit 1; }
done
if [ -z "$LV2_PATH" ]; then
	echo "omx-modgui-sync: LV2_PATH is not set" >&2
	exit 1
fi
command -v plugin-hostd-probe >/dev/null || scan=0

# plugin-hostd's descriptor_dir, when its config names one
conf_dir=$(sed -n 's/^descriptor_dir[[:space:]]\{1,\}//p' "$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf" 2>/dev/null | tail -n 1)
[ -n "$conf_dir" ] && DESCRIPTOR_DIRS="$conf_dir:$DESCRIPTOR_DIRS"

# The descriptors packages installed, one file per line: omx-panel knows where and which contract major
installed_list=$(omx-panel descriptors --installed) || {
	echo "omx-modgui-sync: omx-panel descriptors --installed failed" >&2
	exit 1
}

mkdir -p "$MODGUI_DIR" "$STATE_DIR"

# One line per LV2 plugin: uri, bundle dir, has a MOD GUI outside MODGUI_DIR
# (1/0), descriptor (installed:<package>/<name>:<path>, file:<path> or -), name.
plan() {
	python3 -I - "$MODGUI_DIR" "$DESCRIPTOR_DIRS:$SCAN_DIR" "$installed_list" <<'EOF'
import glob, hashlib, json, os, re, sys
from urllib.parse import unquote, urlparse

modgui_dir, descriptor_dirs, installed_list = sys.argv[1:4]
own = os.path.realpath(modgui_dir)
os.environ["LV2_PATH"] = ":".join(p for p in os.environ["LV2_PATH"].split(":")
                                  if p and os.path.realpath(p) != own)
import lilv

def lv2_uri(path, formats=("lv2",)):
    try:
        with open(path) as f:
            p = json.load(f).get("plugin", {})
    except (OSError, ValueError):
        return None
    return p.get("uri") if p.get("format") in formats and p.get("uri") else None

# A declaration names the LV2 URI whatever format it was written for
installed = {}
for path in sorted(installed_list.split("\n")):
    uri = lv2_uri(path, ("lv2", "clap")) if path else None
    if uri:
        parts = path.split(os.sep)
        installed[uri] = ("%s/%s" % (parts[-3], os.path.splitext(parts[-1])[0]), path)

scanned = {}
for d in descriptor_dirs.split(":"):
    for path in glob.glob(os.path.join(d, "*.json")) if d else []:
        uri = lv2_uri(path)
        if uri and (uri not in scanned or os.path.getmtime(path) > os.path.getmtime(scanned[uri])):
            scanned[uri] = path

world = lilv.World()
world.load_all()
gui = world.new_uri("http://moddevices.com/ns/modgui#gui")
names = set()
for plugin in sorted(world.get_all_plugins(), key=lambda p: str(p.get_uri())):
    uri = str(plugin.get_uri())
    bundle = unquote(urlparse(str(plugin.get_bundle_uri())).path).rstrip("/")
    has_gui = 1 if len(plugin.get_value(gui)) else 0
    if uri in installed:
        src = "installed:%s:%s" % installed[uri]
    elif uri in scanned:
        src = "file:" + scanned[uri]
    else:
        src = "-"
    stem = os.path.basename(bundle)
    stem = stem[:-4] if stem.endswith(".lv2") else stem
    tail = re.split(r"[/#:]", uri.rstrip("/#"))[-1]
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", stem if tail in stem else "%s-%s" % (stem, tail))
    if name in names:
        name = "%s-%s" % (name, hashlib.sha1(uri.encode()).hexdigest()[:8])
    names.add(name)
    print("\t".join((uri, bundle, str(has_gui), src, name)))
EOF
}

generated=0 fresh=0 own_gui=0 no_descriptor=0 no_controls=0 removed=0 failed=0
declare -A wanted

say() { echo "omx-modgui-sync: $*"; }

# A plugin with no control has no panel to draw
has_controls() {
	python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("controls") else 1)' "$1" 2>/dev/null
}

# A descriptor made here for a plugin nobody has scanned yet
scan_descriptor() {
	local uri=$1 name=$2 out="$SCAN_DIR/$2.json" bundle=$3
	if [ -f "$out.failed" ] && [ ! "$bundle/manifest.ttl" -nt "$out.failed" ]; then
		return 1
	fi
	mkdir -p "$SCAN_DIR"
	# shellcheck disable=SC2153 # LV2_PATH comes from the caller
	if timeout "$SCAN_TIMEOUT" plugin-hostd-probe describe "lv2:$uri" >"$out.tmp" 2>/dev/null && [ -s "$out.tmp" ]; then
		mv "$out.tmp" "$out"
		rm -f "$out.failed"
		echo "$out"
		return 0
	fi
	rm -f "$out.tmp"
	touch "$out.failed"
	return 1
}

generate() {
	local uri=$1 name=$2 src=$3 out="$MODGUI_DIR/$2.lv2" tmp args desc_file
	if [ "${src%%:*}" = installed ]; then
		# installed:<package>/<name>:<descriptor file>
		desc_file="${src#installed:}"
		args=(--installed "${desc_file%%:*}")
		desc_file="${desc_file#*:}"
	else
		args=(--descriptor "${src#file:}")
		desc_file="${src#file:}"
	fi
	if [ -e "$out" ] && [ ! -f "$out/$MARKER" ]; then
		say "skip $uri: $out is not ours"
		return
	fi
	if ! has_controls "$desc_file"; then
		no_controls=$((no_controls + 1))
		return
	fi
	if [ -f "$out/$MARKER" ] && [ "$out/modgui.ttl" -nt "$desc_file" ] && [ "$out/manifest.ttl" -nt "$desc_file" ] &&
		[ "$(head -n 1 "$out/$MARKER")" = "$uri" ]; then
		fresh=$((fresh + 1))
		return
	fi
	if [ "$dry_run" = 1 ]; then
		say "would write $out for $uri from ${args[*]}"
		generated=$((generated + 1))
		return
	fi
	tmp=$(mktemp -d "$STATE_DIR/tmp.XXXXXX")
	if ! (cd "$tmp" && omx-panel modgui "${args[@]}" --out "$tmp/$name.lv2" --source "$desc_file" >/dev/null); then
		say "omx-panel could not make a MOD GUI for $uri"
		rm -rf "$tmp"
		failed=$((failed + 1))
		return
	fi
	{
		echo "# Written by omx-modgui-sync.sh for a plugin that ships no MOD GUI."
		echo "# The plugin itself lives in its own bundle; this one adds its GUI."
		grep -v '^#' "$tmp/$name.lv2/modgui.ttl"
	} >"$tmp/$name.lv2/manifest.ttl"
	printf '%s\n%s\n' "$uri" "${args[*]}" >"$tmp/$name.lv2/$MARKER"
	rm -rf "$out"
	mv "$tmp/$name.lv2" "$out"
	rm -rf "$tmp"
	say "wrote $out for $uri"
	generated=$((generated + 1))
}

plan_out=$(plan) || { echo "omx-modgui-sync: could not read the LV2 plugins" >&2; exit 1; }

while IFS=$'\t' read -r uri bundle has_gui src name; do
	[ -n "$uri" ] || continue
	if [ "$has_gui" = 1 ]; then
		own_gui=$((own_gui + 1))
		continue
	fi
	wanted["$name"]=1
	if [ "$src" = - ]; then
		if [ "$scan" = 1 ] && [ "$dry_run" = 0 ] && file=$(scan_descriptor "$uri" "$name" "$bundle"); then
			src="file:$file"
		else
			no_descriptor=$((no_descriptor + 1))
			continue
		fi
	fi
	generate "$uri" "$name" "$src"
done <<<"$plan_out"

# Ours, no longer wanted: the plugin is gone or ships a MOD GUI now
for marker in "$MODGUI_DIR"/*.lv2/"$MARKER"; do
	[ -f "$marker" ] || continue
	bundle=${marker%/*}
	name=${bundle##*/}
	name=${name%.lv2}
	[ -n "${wanted[$name]}" ] && continue
	uri=$(head -n 1 "$marker")
	if [ "$dry_run" = 1 ]; then
		say "would remove $bundle"
	else
		rm -rf "$bundle"
		say "removed $bundle: $uri ships its own MOD GUI now or is gone"
	fi
	removed=$((removed + 1))
done

say "$generated written, $fresh up to date, $own_gui ship their own, $no_descriptor without a descriptor," \
	"$no_controls without controls, $removed removed, $failed failed"
if [ $((generated + removed)) -gt 0 ] && [ "$dry_run" = 0 ]; then
	say "MOD-UI shows the change the next time it starts"
fi
[ "$failed" = 0 ]
