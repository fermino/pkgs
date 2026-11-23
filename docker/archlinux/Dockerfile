# syntax=docker/dockerfile:1
# Builder image: plain Arch (x86_64) or the Arch aarch64 port, plus what builder.nu needs.
#   docker build --build-arg ARCH=x86_64 -t archlinux:x86_64 docker/archlinux/
ARG ARCH=x86_64

FROM scratch AS bootstrap-x86_64
ADD --unpack=true https://fastly.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst /
FROM scratch AS bootstrap-aarch64
ADD --unpack=true https://arch-linux-repo.drzee.net/arch/tarballs/os/aarch64/archlinux-bootstrap-latest-aarch64.tar.zst /

FROM scratch AS base-x86_64
COPY --from=bootstrap-x86_64 /root.x86_64/ /
FROM scratch AS base-aarch64
COPY --from=bootstrap-aarch64 /root.aarch64/ /

FROM base-${ARCH}

RUN <<EOT
    set -euo pipefail

    pacman-key --init
    pacman-key --populate

    case "$(uname -m)" in
        x86_64)
            echo 'Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
            ;;
        aarch64)
            echo 'Server = https://arch-linux-repo.drzee.net/arch/$repo/os/$arch' > /etc/pacman.d/mirrorlist
            curl -sL https://arch-linux-repo.drzee.net/arch/extra/os/aarch64/public.key | pacman-key --add -
            pacman-key --lsign-key 9B2C213B21883BB65CE2FB900CF25682E6BA0751
            ;;
        *)
            echo "unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    # Landlock isn't available in most container runtimes
    sed -i 's/^#DisableSandboxFilesystem$/DisableSandboxFilesystem/' /etc/pacman.conf
    pacman -Syu --noconfirm --needed \
        base-devel git nushell rclone sudo \
        sequoia-sq sequoia-sqv sequoia-chameleon-gnupg
EOT

# Sequoia stands in for GnuPG in makepkg (validpgpkeys checks). builder.nu puts this dir
# first in PATH for makepkg only; pacman-key and pacman keep using GnuPG.
RUN mkdir -p /usr/local/lib/sequoia-gpg && ln -s /usr/bin/gpg-sq /usr/local/lib/sequoia-gpg/gpg

# Unprivileged build user; makepkg -s needs sudo for pacman
RUN <<EOT
    set -euo pipefail
    useradd --user-group --create-home --home-dir /home/builder builder
    echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
    sudo -u builder -H mkdir -m 700 /home/builder/.gnupg
    echo 'keyserver hkps://keyserver.ubuntu.com' | sudo -u builder tee /home/builder/.gnupg/gpg.conf > /dev/null
EOT

# nutest (for the test suite)
RUN <<EOT
    set -euo pipefail
    cd /tmp
    sudo -u builder git clone https://aur.archlinux.org/nutest-git.git
    sudo -u builder git -C nutest-git switch --detach c51f3def37c21b231e662401fdfe587a4e0a8fe7
    cd nutest-git
    sudo -u builder -H makepkg -si --noconfirm
    cd /tmp
    rm -rf nutest-git
    pacman -Scc --noconfirm
EOT

WORKDIR /src
