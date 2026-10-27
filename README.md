# Zynthian System Scripts & Configuration files

[Zynthian](http://zynthian.org) is an Open Synth Platform based on Raspberry Pi, Linux and Free Software Synthesizers.

The [ZynthianOS SD-image](https://os.zynthian.org/zynthianos-last-stable.zip) has all the software you need for building a ZynthianBox, including a good amount of sound libraries and presets.

This repository contains system scripts & configuration files.

## OpenMixer repository

This fork adds the OpenMixer apt repository. It brings plugin-hostd (a crash-safe drop-in for mod-host), omx-clap-host (CLAP and LV2 plugins driven like mod-host), omx-plugins (OpenMixer effects as CLAP and LV2) and omx-panel (panels and MOD GUIs generated from what each plugin declares).

The repository comes from the `openmixer-release` package, which installs the signing key in `/usr/share/keyrings` and links the apt source for the running Debian release (bookworm or trixie) in `/etc/apt/sources.list.d/openmixer.sources`. Packages are built for arm64 and amd64.

The system setup scripts install `openmixer-release` with the other repositories and then run `scripts/recipes/install_openmixer.sh`. On a running Zynthian, run the recipe by hand:

```
$ZYNTHIAN_RECIPE_DIR/install_openmixer.sh
```

It adds the repository if missing and installs the missing packages, so running it again is safe; `--upgrade` also upgrades them. `scripts/update_system_image.sh` runs it with `--upgrade`, so an updated image carries the newest versions.

## OpenMixer in this Zynthian

OpenMixer is part of the default install. A new image built from this fork, and an existing Zynthian on its next `update_zynthian_sys.sh` (or `update_system_image.sh`), end up with:

- the OpenMixer repository and plugin-hostd, omx-clap-host (with omx-clap-scan), omx-plugins, omx-panel and plugin-qualify;
- plugin-hostd as the mod-host of MOD-UI (`ZYNTHIAN_MODHOST_BACKEND=plugin-hostd`) and as the engine the UI menus offer LV2 plugins through (`ZYNTHIAN_PLUGIN_ENGINE=plugin-hostd`);
- `/zynthian/config/plugin-hostd.conf` with `require_pins 1`, `pin_mode first-use` and `pin_file /var/lib/omx/qualified.pins`: a plugin the sync qualified in-process shares a worker and chains, one it refused is not loaded, and one it has not reached yet still loads, in a worker of its own;
- the qualification sync: `plugin-qualify-sync.timer` runs it two minutes after every boot at the lowest CPU and disk priority, and `plugin-qualify-sync.path` when a plugin directory changes. A plugin whose files are unchanged is skipped, so only the first boot after install (or after new plugins) takes long. `/etc/omx/qualify.conf` lists Zynthian's plugin directories (`config/qualify.conf`), and each run starts `omx-modgui-sync.service`.

All of it is done by `scripts/recipes/install_openmixer.sh`, which the setup scripts and `update_zynthian_sys.sh` run. Each step is done once and listed in `/zynthian/config/openmixer-defaults`, so a setting changed by hand afterwards stays. It starts and restarts nothing: its report says what changed and what applies at the next start of mod-host, mod-ui or zynthian. `tests/default-install-check.sh` checks all of it in a container.

To go back, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load      # MOD-UI on mod-host in JACK
sed -i 's/^export ZYNTHIAN_PLUGIN_ENGINE=.*/export ZYNTHIAN_PLUGIN_ENGINE="jalv"/' /zynthian/config/zynthian_envars.sh
systemctl disable --now plugin-qualify-sync.timer plugin-qualify-sync.path
sed -i 's/^require_pins .*/require_pins 0/' /zynthian/config/plugin-hostd.conf
```

An image builder can ship the image already qualified: after the setup script, run `scripts/omx_prequalify_image.sh` on the assembled system. It runs the sync once and writes the pin file, records and descriptors where the services read them; it packages nothing. It must run natively on arm64 (a Raspberry Pi): the results are keyed by the hashes of the plugin files and measured on the CPU, so it refuses to run elsewhere or under emulation. Without it, the first boot does the same work in the background.

## plugin-hostd as the mod-host of MOD-UI

MOD-UI talks to a mod-host on port 5555. `ZYNTHIAN_MODHOST_BACKEND` in `zynthian_envars.sh` picks what answers there:

- `plugin-hostd` (the default): plugin-hostd on ports 5555 and 5556, each plugin in a worker process of its own, so a plugin that crashes takes only its own worker down. It runs LV2 and CLAP plugins. Without plugin-hostd installed, `jack_load` is used.
- `jack_load`: mod-host loaded into JACK as an internal client, as before.

`mod-host.service` runs `sbin/mod-host-backend.sh`, which honours the setting, removes the other backend before it starts and on stop removes whichever one runs. To switch, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh plugin-hostd
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load
```

It stops MOD-UI and mod-host, writes the setting and starts MOD-UI again if it was running, saying each step. Without an argument it prints the setting and what runs. plugin-hostd reads `/zynthian/config/plugin-hostd.conf`, copied from `config/plugin-hostd.conf` once; that file explains each setting. `tests/modhost-backend-check.sh` checks the plugin-hostd backend end to end.

## MOD GUIs from omx-panel

MOD-UI draws a plugin with the MOD GUI the plugin ships. For an LV2 plugin that ships none, `scripts/omx-modgui-sync.sh` makes one with `omx-panel modgui` from the plugin's descriptor, so MOD-UI shows a panel for every plugin.

- Each GUI is a bundle of its own in `/zynthian/zynthian-my-data/modgui`, which is on `LV2_PATH`. Its `manifest.ttl` holds the GUI triples and declares no plugin, so lilv adds the GUI to the installed plugin and the plugin's own bundle is never touched.
- The descriptor is the plugin's declaration in omx-contract for our own plugins, else one written by plugin-hostd or plugin-qualify in `/var/lib/omx/descriptors`, else one made by `plugin-hostd-probe describe` and kept in `/var/lib/omx/modgui-sync`.
- A bundle newer than its descriptor is left as it is. A bundle without the sync's marker file is never written or removed. A generated GUI goes away when its plugin is removed or starts shipping its own.
- `omx-modgui-sync.service` runs it at boot and, through `/etc/apt/apt.conf.d/80omx-modgui-sync`, after each apt run. MOD-UI shows new GUIs the next time it starts.

The OpenMixer plugins (omx-plugins-lv2) ship their MOD GUI inside their bundles in `/usr/lib/lv2`, listed in each `manifest.ttl`. MOD-UI reads them from there like any other plugin's, and the sync leaves them alone. `tests/omx-modgui-sync-check.sh` checks the sync.

You can learn more about the Zynthian Project in any of our sites: 

+ [website](https://zynthian.org)
+ [wiki](https://wiki.zynthian.org)
+ [user's guide](https://help.zynthian.org)
+ [blog](https://blog.zynthian.org)
+ [forum](https://discourse.zynthian.org) => Join the conversation!!

You can buy official kits in the zynthian shop:

+ [shop](https://shop.zynthian.org)
