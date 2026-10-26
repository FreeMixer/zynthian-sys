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

You can learn more about the Zynthian Project in any of our sites: 

+ [website](https://zynthian.org)
+ [wiki](https://wiki.zynthian.org)
+ [user's guide](https://help.zynthian.org)
+ [blog](https://blog.zynthian.org)
+ [forum](https://discourse.zynthian.org) => Join the conversation!!

You can buy official kits in the zynthian shop:

+ [shop](https://shop.zynthian.org)
