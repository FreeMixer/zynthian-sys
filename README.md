# Zynthian System Scripts & Configuration files

[Zynthian](http://zynthian.org) is an Open Synth Platform based on Raspberry Pi, Linux and Free Software Synthesizers.

The [ZynthianOS SD-image](https://os.zynthian.org/zynthianos-last-stable.zip) has all the software you need for building a ZynthianBox, including a good amount of sound libraries and presets.

This repository contains system scripts & configuration files.

## OpenMixer repository

The OpenMixer apt repository brings plugin-hostd, a drop-in for mod-host that runs each plugin in a worker process of its own, and omx-clap-host, the program those workers run CLAP plugins and plugin-hostd's LV2 adapter in. Installing them changes nothing that runs: mod-host, MOD-UI and the UI's engines stay as they are until a setting picks plugin-hostd.

The repository comes from the `openmixer-release` package, which installs the signing key in `/usr/share/keyrings` and links the apt source for the running Debian release (bookworm or trixie) in `/etc/apt/sources.list.d/openmixer.sources`. Packages are built for arm64 and amd64.

The system setup scripts install `openmixer-release` with the other repositories and then run `scripts/recipes/install_openmixer.sh`. On a running Zynthian, run the recipe by hand:

```
$ZYNTHIAN_RECIPE_DIR/install_openmixer.sh
```

It adds the repository if missing and installs the missing packages, so running it again is safe; `--upgrade` also upgrades them. `scripts/update_system_image.sh` runs it with `--upgrade`, so an updated image carries the newest versions.

## plugin-hostd as the mod-host of MOD-UI

MOD-UI talks to a mod-host on port 5555. `ZYNTHIAN_MODHOST_BACKEND` in `zynthian_envars.sh` picks what answers there:

- `jack_load` (the default): mod-host loaded into JACK as an internal client, as before.
- `plugin-hostd`: plugin-hostd on ports 5555 and 5556, each plugin in a worker process of its own, so a plugin that crashes takes only its own worker down. It runs LV2 and CLAP plugins.

`mod-host.service` runs `sbin/mod-host-backend.sh`, which honours the setting, removes the other backend before it starts and on stop removes whichever one runs. It starts plugin-hostd with `sbin/plugin-hostd-start.sh <port> [<feedback port>]`, the one place a plugin-hostd is started on this image: a second daemon on another port (the UI engine of the next change) is started with it too. The script leaves a daemon already running on the port as it is, and otherwise returns once the daemon prints the line it declares for ready in `/usr/share/plugin-hostd/protocol.json`. To switch, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh plugin-hostd
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load
```

It stops MOD-UI and mod-host, writes the setting and starts MOD-UI again if it was running, saying each step. Without an argument it prints the setting and what runs. plugin-hostd reads `/zynthian/config/plugin-hostd.conf`, copied from `config/plugin-hostd.conf` on first use; that file explains each setting. `tests/modhost-backend-check.sh` checks the plugin-hostd backend end to end.

## plugin-hostd as the UI's plugin engine

`ZYNTHIAN_PLUGIN_ENGINE` in `zynthian_envars.sh` picks the engine the UI's plugin menus offer LV2 instruments and effects through: `plugin-hostd` (the default) or `jalv`. The UI's plugin-hostd engine runs its own daemon on `ZYNTHIAN_PLUGIN_HOSTD_PORT` (5570), apart from MOD-UI's on 5555, started with `sbin/plugin-hostd-start.sh`. A config made before this default gets the variable once from `install_openmixer.sh`; one that already names an engine is left as it is. To go back, as root:

```
sed -i 's/^export ZYNTHIAN_PLUGIN_ENGINE=.*/export ZYNTHIAN_PLUGIN_ENGINE="jalv"/' /zynthian/config/zynthian_envars.sh
```

## Plugin qualification

`plugin-qualify` measures each installed plugin on this device, once per version of its files: whether it loads, whether it is real-time safe, its latency and its cost. `scripts/recipes/install_openmixer.sh` (which the setup scripts and `update_zynthian_sys.sh` run) installs it and sets up:

- the qualification sync: `plugin-qualify-sync.timer` runs it two minutes after every boot at the lowest CPU and disk priority, and `plugin-qualify-sync.path` when a plugin directory changes. A plugin whose files are unchanged is skipped, so only the first boot after install (or after new plugins) takes long. `/etc/omx/qualify.conf` lists Zynthian's plugin directories (`config/qualify.conf`);
- `/zynthian/config/plugin-hostd.conf` with `require_pins 1`, `pin_mode first-use` and `pin_file /var/lib/omx/qualified.pins`: in plugin-hostd, a plugin the sync qualified in-process may share a worker and chain, one it refused is not loaded, and one it has not reached yet still loads, in a worker of its own. jalv and jack_load's mod-host are not affected;
- `$ZYNTHIAN_MY_DATA_DIR/plugins/lv2` on `LV2_PATH`, for the user's own plugins.

Each step is done once and listed in `/zynthian/config/openmixer-defaults`, so a setting changed by hand afterwards stays, and a package removed by hand is not installed again. It starts and restarts nothing; its report says what changed. `tests/default-install-check.sh` checks all of it in a container.

To turn it off, as root:

```
systemctl disable --now plugin-qualify-sync.timer plugin-qualify-sync.path
sed -i 's/^require_pins .*/require_pins 0/' /zynthian/config/plugin-hostd.conf
```

An image builder can ship the image already qualified: after the setup script, run `scripts/omx_prequalify_image.sh` on the assembled system. It runs the sync once and writes the pin file, records and descriptors where the services read them; it packages nothing. It must run natively on arm64 (a Raspberry Pi): the results are keyed by the hashes of the plugin files and measured on the CPU, so it refuses to run elsewhere or under emulation. Without it, the first boot does the same work in the background.

You can learn more about the Zynthian Project in any of our sites: 

+ [website](https://zynthian.org)
+ [wiki](https://wiki.zynthian.org)
+ [user's guide](https://help.zynthian.org)
+ [blog](https://blog.zynthian.org)
+ [forum](https://discourse.zynthian.org) => Join the conversation!!

You can buy official kits in the zynthian shop:

+ [shop](https://shop.zynthian.org)
