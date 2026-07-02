FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS dev
ARG TARGETARCH
COPY . /src/
WORKDIR /src
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" go build -a -ldflags '-s -w -extldflags "-static"' -o /bootkit

FROM scratch
COPY --from=dev /bootkit .
ENTRYPOINT ["/bootkit"]
