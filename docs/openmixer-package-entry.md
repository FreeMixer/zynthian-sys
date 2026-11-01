# OpenMixer as an entry in webconf's package list

This is a description only. Nothing here changes a repository.

Since the package system of 2026-10-30, zynthian-webconf lists what `zynthian-packages` offers and keeps what is installed under `$ZYNTHIAN_CONFIG_DIR/packages/<category>/<name>/info.yml` (`lib/extrapacks_handler.py`). `sbin/create_installed_packages.sh` fills that directory once from the packages whose script answers `installed`.

OpenMixer could appear in that list as one entry in the zynthian-packages format:

- category: the one that holds audio engines and plugin hosts, or a new `openmixer` category if upstream prefers;
- `openmixer/openmixer.sh`, a script that answers four commands:
  - `installed` prints `installed` when plugin-hostd is installed (`dpkg-query -W plugin-hostd`), else `not installed`;
  - `git_version` prints the installed plugin-hostd version, so webconf can compare it with what the apt channel offers;
  - `install` runs `scripts/recipes/install_openmixer.sh`;
  - `update` runs `scripts/recipes/install_openmixer.sh --upgrade`;
- `openmixer/info.yml` with a name, a one-line description, the category, and `version` taken from the installed plugin-hostd. `create_installed_packages.sh` copies the entry into the installed list when `installed` is answered, so the version there is what the device runs.

The script wraps the recipe and adds no behaviour of its own. The recipe is safe to run twice, starts and restarts nothing, and its last lines say what applies at the next start of mod-host, mod-ui or zynthian; the script passes that output on to webconf.

This is the natural first step to offer upstream: one entry in zynthian-packages, using their own format, with the install path unchanged on devices that do not take it.
