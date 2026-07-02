FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder

ARG TARGETARCH

ENV BUSYBOX_VERSION=1.36.1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  bzip2 \
  ca-certificates \
  curl \
  file \
  gcc \
  libc6-dev \
  make \
  && case "${TARGETARCH}" in \
    amd64) apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross ;; \
    arm64) apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross ;; \
    loong64) apt-get install -y --no-install-recommends gcc-loongarch64-linux-gnu libc6-dev-loong64-cross ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && \
  tar -C /tmp -xjf /tmp/busybox.tar.bz2

WORKDIR /tmp/busybox-${BUSYBOX_VERSION}
RUN make defconfig && \
  for symbol in STATIC MDEV FEATURE_MDEV_CONF FEATURE_MDEV_DAEMON FEATURE_MDEV_EXEC FEATURE_MDEV_LOAD_FIRMWARE ASH SH_IS_ASH; do \
    sed -i "s/^# CONFIG_${symbol} is not set/CONFIG_${symbol}=y/" .config; \
    sed -i "s/^CONFIG_${symbol}=.*/CONFIG_${symbol}=y/" .config; \
    grep -q "^CONFIG_${symbol}=y$" .config || echo "CONFIG_${symbol}=y" >> .config; \
  done && \
  sed -i "s/^CONFIG_TC=.*/# CONFIG_TC is not set/" .config && \
  yes "" | make oldconfig

RUN case "${TARGETARCH}" in \
    amd64) cross=x86_64-linux-gnu- ;; \
    arm64) cross=aarch64-linux-gnu- ;; \
    loong64) cross=loongarch64-linux-gnu- ;; \
  esac && \
  make -j"$(nproc)" CROSS_COMPILE="${cross}" busybox && \
  file busybox

RUN mkdir -p /stage/bin /stage/sbin /stage/lib/systemd /stage/etc/init.d /stage/etc/mdev && \
  cp busybox /stage/bin/busybox && \
  ln -s /bin/busybox /stage/bin/sh && \
  ln -s /bin/busybox /stage/bin/sleep && \
  ln -s /bin/busybox /stage/bin/mount && \
  ln -s /bin/busybox /stage/sbin/mdev && \
  ln -s /usr/bin/service /stage/etc/init.d/030-mdev

FROM scratch
WORKDIR /
ENTRYPOINT []
COPY --from=builder /stage/ /
COPY --chmod=0755 systemd-udevd.sh /lib/systemd/systemd-udevd
CMD ["/lib/systemd/systemd-udevd", "--oneshot"]
