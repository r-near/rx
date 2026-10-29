# Stand-in for the build box: Ubuntu 24.04 with systemd as PID 1, sshd, and box/setup.sh --minimal.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus libpam-systemd dbus-user-session \
      ca-certificates curl git rsync openssh-server sudo procps iproute2 util-linux xfsprogs \
      build-essential pkg-config jq xz-utils unzip >/dev/null && \
    useradd -m -s /bin/bash dev
# Toolchain layer before COPY so editing box/ doesn't re-download Rust; setup.sh then finds it installed.
RUN runuser -u dev -- bash -lc 'curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain stable'
COPY box/ /opt/rx-box/
RUN /opt/rx-box/setup.sh --minimal
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
