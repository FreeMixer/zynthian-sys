# Building the ZynthianOS image with OpenMixer

How the published image is made: upstream's released `vangelis` image, updated offline with this fork's update steps,
so that the Zynthian part stays upstream's release and the OpenMixer part is what this fork installs on any update. How a
user installs and uses the result is at <https://openmixer.org/docs/zynthian>.

## Why from upstream's image

Upstream publishes the `vangelis` images at <https://os.zynthian.org/> and publishes no builder for them: the
[ZynthianOS](https://github.com/zynthian/ZynthianOS) CustomPiOS distribution targets Raspbian stretch and does not build
`vangelis`, and `scripts/setup_system_raspioslite_64bit_trixie.sh` makes a system by compiling the whole stack on a Pi
booted from Raspberry Pi OS Lite, which takes many hours and rebuilds what upstream already released. Updating upstream's
image offline takes about seven minutes after the download, from inputs that are all public: upstream's image (by its
sum), this fork's commits and the OpenMixer packages. It is what a Zynthian owner gets by flashing upstream's image and
running this fork's update.

## What you need

An x86-64 Linux host with sudo, `systemd-nspawn`, `growpart`, `resize2fs`, `xz` and a static `qemu-aarch64`, and a
checkout of [plugin-hostd](https://github.com/FreeMixer/plugin-hostd), whose `tools/zynthian/` holds the build scripts.

## Build it

On Fedora, the static qemu is taken from its package without installing it; the script registers its binfmt entry only
for the build when none exists, and removes it afterwards.

```
mkdir -p zynthian-image/{dl,qemu}
cd zynthian-image/dl
curl -sSfLO https://os.zynthian.org/2026-10-15-zynthianos-vangelis-2610-stable.img.xz
curl -sSfLO https://os.zynthian.org/2026-10-15-zynthianos-vangelis-2610-stable.img.xz.md5
md5sum -c 2026-10-15-zynthianos-vangelis-2610-stable.img.xz.md5
cd ../qemu && dnf download qemu-user-static-aarch64 && rpm2cpio qemu-user-static-aarch64-*.rpm | cpio -idm
cd .. && QEMU_AARCH64=$PWD/qemu/usr/bin/qemu-aarch64-static \
    <plugin-hostd>/tools/zynthian/image-build.sh dl/2026-10-15-zynthianos-vangelis-2610-stable.img.xz out
```

`image-build.sh` decompresses the image, grows it by 2 GiB (the first boot still expands the root file system to the
card), loop-mounts both partitions and, in a `systemd-nspawn` of the root file system:

1. points `/zynthian/zynthian-sys` and `/zynthian/zynthian-ui` at this fork and FreeMixer's zynthian-ui, branch
   `vangelis`, so later updates on the device follow the forks;
2. runs `update_zynthian_sys.sh`: this fork's system files, `config.txt` from its template, and
   `scripts/recipes/install_openmixer.sh` (the OpenMixer repository and packages, `ZYNTHIAN_MODHOST_BACKEND` and
   `ZYNTHIAN_PLUGIN_ENGINE` set to plugin-hostd, `plugin-hostd.conf`, `qualify.conf`, the qualification sync enabled);
3. runs `update_zynthian_code.sh` (the UI fork pulled, zyncoder and zynlibs rebuilt), then `install_openmixer.sh --upgrade`;
4. clears the apt caches and lists, the logs and root's history, and adds the fork commits to `/zynthian/build_info.txt`.

It then checks the file system, runs `tools/zynthian/image-inspect.sh` on the result, and writes
`zynthianos-vangelis-omx.img.xz` and its `.sha256`; `config.txt.diff` shows what the update changed in
`/boot/firmware/config.txt`.

Inside the nspawn the board is not detected, so the steps that read the sound card or the ALSA mixer are skipped by the
scripts themselves, as under any virtualization, and `config.txt` is the template's, with both the Pi 4 and Pi 5 sections;
the first boot sets the rest, as for upstream's image. `systemctl` has no running systemd there: `daemon-reload` and the
restarts the update scripts ask for are skipped, which is right for an image, and `enable` works. `update_zynthian_code.sh`
exits 1 for that reason alone (its last step restarts the web configuration), after the engines database is regenerated.
A command the scripts cannot find fails the build.

The plugins are not qualified in the image: `scripts/omx_prequalify_image.sh` must run on a Pi, since the records are keyed
by the plugin files' hashes and measured on its CPU. Without it, the first boot qualifies them at low priority two minutes
after boot.

## Check it

- `tools/zynthian/image-inspect.sh` (no root): `/zynthian/build_info.txt` names upstream's build and the fork commits; the
  OpenMixer packages have versions; `zynthian-sys` and `zynthian-ui` are on `vangelis` at the forks' commits.
- `/zynthian/config/zynthian_envars.sh` in the image sets `ZYNTHIAN_MODHOST_BACKEND="plugin-hostd"` and
  `ZYNTHIAN_PLUGIN_ENGINE="plugin-hostd"`, and `/zynthian/config/openmixer-defaults` lists the steps done.
- `tools/zynthian/image-first-boot-qemu.sh` boots the image under full emulation (with a generic arm64 kernel, since the
  image's own has no virtio block driver) to check the first boot's userland; the first boot on a Pi is checked by hand:
  the UI comes up, MOD-UI runs on plugin-hostd, a chain with an LV2 and a CLAP plugin sounds, and the qualification sync
  has filled `/var/lib/omx/qualified.pins`.

## Publish it

As a release of this repository, named after the upstream image and the fork commit it carries (for example
`vangelis-2610-omx-<short sha>`), with the `image-inspect.sh` output in the notes. GitHub takes release assets up to
2 GiB and the image is larger, so it is published in parts with the sum of the joined file and of each part:

```
split -b 1900M -d -a 2 zynthianos-vangelis-omx.img.xz zynthianos-vangelis-omx.img.xz.
```
