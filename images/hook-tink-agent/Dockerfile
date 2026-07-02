FROM --platform=$BUILDPLATFORM golang:1.25.7-bookworm AS builder

ARG TARGETARCH
ARG TINKERBELL_REF=v0.23.0

ENV CGO_ENABLED=0
ENV GOOS=linux

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${TINKERBELL_REF}" https://github.com/tinkerbell/tinkerbell.git /src
WORKDIR /src
RUN GOARCH="${TARGETARCH}" go build -trimpath -tags "${GO_TAGS}" -ldflags="-s -w" -o /out/tink-agent ./cmd/agent && \
  cp LICENSE /out/LICENSE && \
  printf 'Built from https://github.com/tinkerbell/tinkerbell at ref %s for linux/%s.\n' "${TINKERBELL_REF}" "${TARGETARCH}" > /out/THIRD_PARTY_LICENSES

FROM --platform=$BUILDPLATFORM debian:trixie-slim AS ca-certs
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

FROM scratch
ENTRYPOINT [ "/tink-agent" ]
COPY --from=builder /out/tink-agent /tink-agent
COPY --from=ca-certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/LICENSE /usr/share/doc/tinkerbell/LICENSE
COPY --from=builder /out/THIRD_PARTY_LICENSES /usr/share/doc/tinkerbell/THIRD_PARTY_LICENSES
