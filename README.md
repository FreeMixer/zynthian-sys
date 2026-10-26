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

It adds the repository if missing and installs or upgrades the packages, so running it again is safe. `scripts/update_system_image.sh` runs it too, so an updated image carries the newest versions.

## plugin-hostd as the mod-host of MOD-UI

MOD-UI talks to a mod-host on port 5555. `ZYNTHIAN_MODHOST_BACKEND` in `zynthian_envars.sh` picks what answers there:

- `jack_load` (the default): mod-host loaded into JACK as an internal client, as before.
- `plugin-hostd`: plugin-hostd on ports 5555 and 5556, each plugin in a worker process of its own, so a plugin that crashes takes only its own worker down. It runs LV2 and CLAP plugins.

`mod-host.service` runs `sbin/mod-host-backend.sh`, which honours the setting, removes the other backend before it starts and on stop removes whichever one runs. To switch, as root:

```
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh plugin-hostd
/zynthian/zynthian-sys/sbin/set_modhost_backend.sh jack_load
```

It stops MOD-UI and mod-host, writes the setting and starts MOD-UI again if it was running, saying each step. Without an argument it prints the setting and what runs. plugin-hostd reads `/zynthian/config/plugin-hostd.conf`, copied from `config/plugin-hostd.conf` on first use; that file explains each setting. `tests/modhost-backend-check.sh` checks the plugin-hostd backend end to end.

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
