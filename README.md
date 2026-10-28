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

You can learn more about the Zynthian Project in any of our sites: 

+ [website](https://zynthian.org)
+ [wiki](https://wiki.zynthian.org)
+ [user's guide](https://help.zynthian.org)
+ [blog](https://blog.zynthian.org)
+ [forum](https://discourse.zynthian.org) => Join the conversation!!

You can buy official kits in the zynthian shop:

+ [shop](https://shop.zynthian.org)
