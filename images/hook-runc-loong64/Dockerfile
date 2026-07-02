# Dockerfile to build a LoongArch runc image for LinuxKit.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV GOPATH=/go PATH=/usr/local/go/bin:/go/bin:$PATH GO111MODULE=off
ENV RUNC_COMMIT=v1.3.0
ENV GO_VERSION=1.24.5

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  curl \
  file \
  git \
  make \
  xz-utils \
  gcc-loongarch64-linux-gnu \
  libc6-dev-loong64-cross \
  && rm -rf /var/lib/apt/lists/*

RUN build_arch="$(dpkg --print-architecture)" && \
  case "${build_arch}" in \
    amd64) go_arch=amd64 ;; \
    arm64) go_arch=arm64 ;; \
    *) echo "unsupported build architecture ${build_arch}" >&2; exit 1 ;; \
  esac && \
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" | tar -C /usr/local -xz

RUN mkdir -p $GOPATH/src/github.com/opencontainers && \
  cd $GOPATH/src/github.com/opencontainers && \
  git clone https://github.com/opencontainers/runc.git

WORKDIR $GOPATH/src/github.com/opencontainers/runc
RUN git checkout $RUNC_COMMIT
RUN CGO_ENABLED=1 GOOS=linux GOARCH=loong64 CC=loongarch64-linux-gnu-gcc \
  make static BUILDTAGS="urfave_cli_no_docs" EXTRA_LDFLAGS="-s -w" && \
  file runc

RUN mkdir -p /stage/etc/init.d /stage/etc/shutdown.d && \
  ln -s /usr/bin/service /stage/etc/init.d/010-onboot && \
  ln -s /usr/bin/service /stage/etc/shutdown.d/010-onshutdown

FROM scratch
WORKDIR /
ENTRYPOINT []
COPY --from=builder /go/src/github.com/opencontainers/runc/runc /usr/bin/
COPY --from=builder /stage/ /
