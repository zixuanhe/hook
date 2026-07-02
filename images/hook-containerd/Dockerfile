FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

ARG TARGETARCH

# checkout and compile containerd
# Update `FROM` in `pkg/containerd/Dockerfile`, `pkg/init/Dockerfile` and
# `test/pkg/containerd/Dockerfile` when changing this.
ENV CONTAINERD_REPO=https://github.com/containerd/containerd.git

ENV CONTAINERD_COMMIT=v2.1.3
ENV NERDCTL_VERSION=2.1.2
ENV GOPATH=/go
RUN apk add --no-cache git
RUN mkdir -p $GOPATH/src/github.com/containerd && \
  cd $GOPATH/src/github.com/containerd && \
  git clone https://github.com/containerd/containerd.git && \
  cd $GOPATH/src/github.com/containerd/containerd && \
  git checkout $CONTAINERD_COMMIT
WORKDIR $GOPATH/src/github.com/containerd/containerd
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" go build -trimpath -tags "netgo osusergo no_btrfs no_devmapper urfave_cli_no_docs" -ldflags "-w -s" -o /usr/bin/containerd ./cmd/containerd && \
  CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" go build -trimpath -tags "netgo osusergo no_btrfs no_devmapper urfave_cli_no_docs" -ldflags "-w -s" -o /usr/bin/ctr ./cmd/ctr && \
  CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" go build -trimpath -tags "netgo osusergo no_btrfs no_devmapper urfave_cli_no_docs no_grpc" -ldflags "-w -s" -o /usr/bin/containerd-shim-runc-v2 ./cmd/containerd-shim-runc-v2

# install nerdctl
RUN if [ "$TARGETARCH" = "amd64" ]; then ARCHITECTURE=amd64; elif [ "$TARGETARCH" = "arm64" ]; then ARCHITECTURE=arm64; elif [ "$TARGETARCH" = "loong64" ]; then ARCHITECTURE=loong64; else ARCHITECTURE=amd64; fi \
  && wget https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${ARCHITECTURE}.tar.gz \
  && tar -zxvf nerdctl-${NERDCTL_VERSION}-linux-${ARCHITECTURE}.tar.gz -C /usr/local/bin/

RUN mkdir -p /opt/containerd

FROM --platform=$BUILDPLATFORM alpine:3.22 AS rootfs
RUN apk add --no-cache ca-certificates tzdata && \
  mkdir -p /etc/init.d && ln -s /usr/bin/service /etc/init.d/020-containerd

FROM scratch AS containerd-dev
ENTRYPOINT []
WORKDIR /
COPY --from=builder /usr/bin/containerd /usr/bin/ctr /usr/bin/containerd-shim-runc-v2 /usr/bin/
COPY --from=builder /go/src/github.com/containerd/containerd /go/src/github.com/containerd/containerd
COPY --from=builder /usr/local/bin/nerdctl /usr/bin/
COPY --from=builder /opt/containerd/ /opt/containerd/

FROM containerd-dev

FROM scratch
ENTRYPOINT []
WORKDIR /
COPY --from=containerd-dev /usr/bin/containerd /usr/bin/ctr /usr/bin/containerd-shim-runc-v2 /usr/bin/
COPY --from=containerd-dev /usr/bin/nerdctl /usr/bin/
COPY --from=containerd-dev /opt/containerd/ /opt/containerd/
COPY --from=rootfs /usr/share/zoneinfo/UTC /etc/localtime
COPY --from=rootfs /etc/init.d/ /etc/init.d/
COPY --from=rootfs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY etc etc/
