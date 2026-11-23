# pacman repo builder

Builds Arch packages from a list of git repos (PKGBUILD + .SRCINFO) for several targets and hosts them as signed pacman repos on any rclone-reachable storage.

- **`config.toml`**: repo name, rclone remote, targets, sources.
- **`builder.nu`**: `plan` / `build` / `publish` / `index`, written in nushell. The pure logic lives in **`lib.nu`** and is unit-tested in `tests/`.
- **GitHub Actions**: `build.yml` runs every 3 hours, on manual dispatch (with `force`) and on pushes to `config.toml`. `images.yml` builds the builder images weekly. `test.yml` runs the tests.

## How it works

```
plan (x86_64)                         build <target> (matrix, native runners)      publish (x86_64)
- clone sources, read .SRCINFO        - makepkg as `builder` user                 - sq sign packages
- fetch + verify each target's db     - target's makepkg_conf drop-in             - repo-add / repo-remove
  and state (sqv vs keys/repo.pgp)    - earlier builds available as deps          - sign db, files, state
- git ls-remote for -git sources      - artifact: packages + built.nuon           - upload pkgs, then metadata
- decide what to build / remove                                                   - delete unreferenced files
                                                                                  - write index.html listings
```

**When does a source get built?**
- **Normal packages**: when any of its pkgnames is missing from the target's db, or its version differs from `.SRCINFO` (`[epoch:]pkgver-pkgrel`).
- **VCS packages** (any `git+`/`svn+`/... source without a pinned `#tag=`/`#commit=`): when a package is missing, when the packaging directory's git tree changed, or when `git ls-remote` reports a new commit for a tracked `git+` source (`#branch=` respected). The commits a package was built from are kept in `<repo>.state.nuon` next to the db, signed like everything else. Nothing is cloned or run from upstream at plan time.
- **`force`**: everything.

**Targets.** A source builds for every configured target its `arch=()` allows. A source's `targets: [...]` narrows that. `arch=any` packages are built once, on the first target that needs them, and published to every target that needs them.

**Cleanup.** After a publish, every package file (and `.sig`) in a target folder that its db doesn't reference is deleted. That covers both old versions and sources dropped from the config, which are `repo-remove`d first.

**Sequoia.** Packages, dbs and the state file are signed with `sq sign`, and remote metadata is verified with `sqv`. Inside the build, makepkg gets `gpg-sq` (sequoia-chameleon-gnupg) as its `gpg`, so `validpgpkeys` source checks run on Sequoia. A source's `keys/pgp/*.asc` are imported first. pacman and pacman-key keep using GnuPG; the chameleon can't lsign keys in pacman's keyring.

**Safety.** If any source can't be cloned or parsed, or an `ls-remote` fails, `plan` stops. That keeps a network glitch from being read as "source removed", which would delete its packages. Remote metadata is verified against `keys/repo.pgp` before it is used. A failed build leaves that package's previous version in place; the other packages still publish.

## Remote layout

```
<remote>/repo.pgp                                 public signing key
<remote>/index.html, <remote>/archlinux/index.html folder listings
<remote>/archlinux/<target>/<repo>.db{,.sig}
<remote>/archlinux/<target>/<repo>.files{,.sig}
<remote>/archlinux/<target>/<repo>.state.nuon{,.sig}
<remote>/archlinux/<target>/*.pkg.tar.zst{,.sig}
<remote>/archlinux/<target>/index.html
```

Packages sit under a distro folder (`archlinux/`), so other distros can go next to it later. The remote's root is served at https://pkgs.fermino.me/.

**Browsing.** B2 can't list folders, so every `publish` ends by running `index`. It writes a static `index.html` into each target folder, `archlinux/` and the root, listing that folder's files (size and mtime from `rclone lsjson`). Cleanup only touches package files, so the listings are never deleted.

## Setup

1. **Signing key** (Sequoia):
   ```bash
   sq --home=none key generate --own-key --without-password --name 'myrepo signing key' --output signing.key --rev-cert signing.rev
   ```
   ```bash
   sq --home=none key delete --cert-file signing.key --output keys/repo.pgp
   ```
   Commit `keys/repo.pgp`. Put the contents of `signing.key` in the `SIGNING_KEY` repository secret (armored text is fine). Keep `signing.key` and `signing.rev` somewhere safe, not in the repo. sq keys expire after 3 years by default (`--expiration` changes that). `publish` refuses to run if the key doesn't match `keys/repo.pgp`.
2. **Storage** (Backblaze B2): create a bucket and an application key restricted to it (read and write). Put the key ID in the `B2_KEY_ID` secret and the key in `B2_APPLICATION_KEY`. Set `remote` in `config.toml` to `repo:<bucket>`. The workflow defines the rclone remote `repo` with `RCLONE_CONFIG_REPO_*` env vars on the `plan` and `publish` steps only, so build jobs never see the key. It sets `hard_delete`, so stale packages are deleted rather than hidden. Overwriting `myrepo.db` and friends still keeps old versions, so set the bucket's lifecycle to keep only the last version. Another backend works too: change the `RCLONE_CONFIG_REPO_*` vars in `build.yml` (see `rclone help backend <name>` for the options; passwords must be `rclone obscure`d).
3. **Browsing** (Cloudflare in front of B2): B2 serves `index.html` only when it's asked for by name. In the zone's URL rewrite Transform Rules, add a rule for folder URLs:
   - When: `ends_with(http.request.uri.path, "/")`
   - Path, dynamic: `concat("/file/<bucket>", http.request.uri.path, "index.html")`

   Add the condition `not ends_with(http.request.uri.path, "/")` to the existing rule that prefixes `/file/<bucket>`, so exactly one of the two rules matches each request. Optionally add a redirect rule from `/archlinux` to `/archlinux/` (and the same for each target) so links without the slash work too. To fill the pages in right away instead of waiting for the next publish, run `nu builder.nu index` with the remote set up (see [Running locally](#running-locally)).
4. **Images**: push to `master`, or run the `images` workflow manually. It publishes `ghcr.io/<owner>/<repo>-archlinux:{x86_64,aarch64}`. The aarch64 image is built from the Arch aarch64 port bootstrap on arch-linux-repo.drzee.net. A target's `image` in `config.toml` must be one of those tags.
5. Edit `config.toml` (repo name, targets, sources), push, and run `build`.

GitHub's `ubuntu-24.04-arm` runners are free for public repositories. They're Neoverse-class, so they also run ARMv8.2 builds and their `check()`s.

## Client

The repo signing key is:

```
56DBB6BB201CDE8366A429B4A58ED0FA6862DD8C
```

It's an Ed25519 key that signs with its subkey `C81A483D0247BB219ED3AC0771C2FDDD500CB5FF`, and it expires on 2029-11-23. A copy is in [keys/repo.pgp](keys/repo.pgp).

```bash
curl -O https://pkgs.fermino.me/repo.pgp
sudo pacman-key --add repo.pgp
sudo pacman-key --lsign-key 56DBB6BB201CDE8366A429B4A58ED0FA6862DD8C
```

pacman only trusts the fingerprint you lsign, so a swapped `repo.pgp` on the host can't make another key trusted. If the key is ever replaced, update the fingerprint here.

```ini
# /etc/pacman.conf
[myrepo]
Server = https://pkgs.fermino.me/archlinux/aarch64-v8.2
```

The folder is the target name and picks the variant: `x86_64`, `aarch64-v8.0` or `aarch64-v8.2`.

## Adding a target

Add a `[targets.<name>]` table to `config.toml`:

```toml
[targets."x86_64-v3"]
arch = "x86_64"
runner = "ubuntu-24.04"
image = "x86_64"
makepkg_conf = '''
CFLAGS="$(sed "s/-march=[^ ]*/-march=x86-64-v3/" <<<"$CFLAGS")"
CXXFLAGS="$(sed "s/-march=[^ ]*/-march=x86-64-v3/" <<<"$CXXFLAGS")"
RUSTFLAGS="$RUSTFLAGS -C target-cpu=x86-64-v3"
'''
```

`makepkg_conf` is bash, written to `/etc/makepkg.conf.d/50-target.conf`, so it runs after the image's `makepkg.conf`. A new architecture (e.g. `riscv64`) also needs an image for it in `docker/archlinux/Dockerfile` + `images.yml` and a runner that can run it.

## Running locally

`plan` and `publish` run anywhere with nu, git, rclone, sqv/sq and pacman's `repo-add`. The `repo` remote can come from your own `rclone.conf` or from the same env vars as CI (`in-builder.sh` passes every `RCLONE_*` variable into the container):

```bash
export RCLONE_CONFIG_REPO_TYPE=b2 RCLONE_CONFIG_REPO_ACCOUNT=<key id> RCLONE_CONFIG_REPO_KEY=<key>
```

`remote` can also be a plain path, so an `rclone mount` works too:

```bash
rclone mount myhost:/srv/pacman /mnt/pacman --daemon
```
```bash
REMOTE=/mnt/pacman nu builder.nu plan
```

`build` changes `/etc/pacman.conf` and `/etc/makepkg.conf.d`, so it refuses to run outside the builder image (it checks for root). Use the image:

```bash
./in-builder.sh x86_64 nu builder.nu build x86_64
```
```bash
SIGNING_KEY=signing.key REMOTE=/mnt/pacman nu builder.nu publish
```

`IMAGE=<name>` makes `in-builder.sh` use a locally built image, e.g. one from `docker build --build-arg ARCH=x86_64 -t <name> docker/archlinux/`. `BUILDER_CONFIG` and `WORK` override the config file and the work directory.

## Tests

```bash
nu -I /usr/share/nushell/modules -c 'use nutest; nutest run-tests --path tests'
```

This needs `nutest-git` from the AUR. The builder images include it, and `test.yml` runs the tests there.

## Limits

- If upstream gets a commit between plan and build, the state records the planned commit, so the package is rebuilt once more on the next run.
- An `arch=any` package built in a run can't be a build dependency for another target's job in the same run; it can from the next run on (with `public_url` set).
- `svn+`/`hg+`/`bzr+`/`fossil+` sources aren't checked upstream. They rebuild when the packaging changes, or with `force`.
- Artifacts don't keep file modes, so packaging dirs arrive in build jobs without executable bits. PKGBUILDs don't normally rely on them.
