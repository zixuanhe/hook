#!/usr/bin/env bash

function build_all_hook_linuxkit_containers() {
	log info "Building all LinuxKit containers..."
	: "${DOCKER_ARCH:?"ERROR: DOCKER_ARCH is not defined"}"

	rm -f images/hook-embedded/images/tink-agent-loong64.tar

	# when adding new container builds here you'll also want to add them to the
	# `linuxkit_build` function in the linuxkit.sh file.
	# # NOTE: linuxkit containers must be in the images/ directory
	build_hook_linuxkit_container hook-bootkit "HOOK_CONTAINER_BOOTKIT_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
	if [[ "${DOCKER_ARCH}" == "loong64" ]]; then
		log info "Skipping hook-docker for loong64; BootKit uses containerd/nerdctl on this architecture."
		hook_template_vars["HOOK_CONTAINER_DOCKER_IMAGE"]="unused-loong64-hook-docker"
	else
		build_hook_linuxkit_container hook-docker "HOOK_CONTAINER_DOCKER_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
	fi
	if [[ "${DOCKER_ARCH}" == "loong64" ]]; then
		build_hook_linuxkit_container hook-mdev "HOOK_CONTAINER_UDEV_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
		log info "Skipping hook-acpid for loong64; ACPI handling is omitted on this experimental architecture."
		hook_template_vars["HOOK_CONTAINER_ACPID_IMAGE"]="unused-loong64-hook-acpid"
	else
		build_hook_linuxkit_container hook-udev "HOOK_CONTAINER_UDEV_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
		build_hook_linuxkit_container hook-acpid "HOOK_CONTAINER_ACPID_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
	fi
	build_hook_linuxkit_container hook-containerd "HOOK_CONTAINER_CONTAINERD_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
	if [[ "${DOCKER_ARCH}" == "loong64" ]]; then
		build_hook_linuxkit_container hook-runc-loong64 "HOOK_CONTAINER_RUNC_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
		build_hook_linuxkit_container hook-tink-agent "HOOK_CONTAINER_TINK_AGENT_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
		prepare_loong64_embedded_tink_agent
	else
		build_hook_linuxkit_container hook-runc "HOOK_CONTAINER_RUNC_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
		hook_template_vars["HOOK_CONTAINER_TINK_AGENT_IMAGE"]="unused-non-loong64-tink-agent"
	fi
	build_hook_linuxkit_container hook-embedded "HOOK_CONTAINER_EMBEDDED_IMAGE" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"

	# We also use a bunch of linuxkit/xxx:v1.0.0 images; those would be pulled from Docker Hub (and thus subject to rate limits) for each Hook build.
	# Instead, we'll wrap them into a Dockerfile with just a FROM line, and build/push them ourselves.
	# Those versions are obtained from the references in https://github.com/linuxkit/linuxkit/tree/master/examples
	declare -A linuxkit_proxy_images=()
	linuxkit_proxy_images+=(["init"]="linuxkit/init:b5506cc74a6812dc40982cacfd2f4328f8a4b12a")
	linuxkit_proxy_images+=(["ca_certificates"]="linuxkit/ca-certificates:256f1950df59f2f209e9f0b81374177409eb11de")
	linuxkit_proxy_images+=(["firmware"]="linuxkit/firmware:68c2b29f28f2639020b9f8d55254d333498a30aa")
	linuxkit_proxy_images+=(["rngd"]="linuxkit/rngd:984eb580ecb63986f07f626b61692a97aacd7198")
	linuxkit_proxy_images+=(["sysctl"]="linuxkit/sysctl:97e8bb067cd9cef1514531bb692f27263ac6d626")
	linuxkit_proxy_images+=(["sysfs"]="linuxkit/sysfs:6d5bd933762f6b216744c711c6e876756cee9600")
	linuxkit_proxy_images+=(["modprobe"]="linuxkit/modprobe:4248cdc3494779010e7e7488fc17b6fd45b73aeb")
	linuxkit_proxy_images+=(["dhcpcd"]="linuxkit/dhcpcd:b87e9ececac55a65eaa592f4dd8b4e0c3009afdb")
	linuxkit_proxy_images+=(["openntpd"]="linuxkit/openntpd:2508f1d040441457a0b3e75744878afdf61bc473")
	linuxkit_proxy_images+=(["getty"]="linuxkit/getty:a86d74c8f89be8956330c3b115b0b1f2e09ef6e0")
	linuxkit_proxy_images+=(["sshd"]="linuxkit/sshd:08e5d4a46603eff485d5d1b14001cc932a530858")

	# each of those will handled the following way:
	# - create+clean a directory under images; eg for key "init" create images/hook-linuxkit-init
	#  (all of images/hook-linuxkit-* are .gitignored)
	# - create a Dockerfile with "FROM --platform=xxx linuxkit/init:v1.1.0" in that directory
	# - determine HOOK_CONTAINER_LINUXKIT_<key:toUpper>_IMAGE variable name
	# - call build_hook_linuxkit_container with that directory and variable name
	# that way, everything else works exactly as with the other images, and there's  now a DockerHub-free way of getting those images
	# it works because build_hook_linuxkit_container does content-based hashing; so tags should be stable for the same version
	# that potentializes the use of caching with docker save/load or other local caching mechanisms.
	declare lk_proxy_image_key="undetermined" lk_proxy_image_ref="undetermined" lk_proxy_image_dir="undetermined" lk_proxy_image_var="undetermined"
	for lk_proxy_image_key in "${!linuxkit_proxy_images[@]}"; do
		lk_proxy_image_ref="${linuxkit_proxy_images[${lk_proxy_image_key}]}"
		lk_proxy_image_dir="hook-linuxkit-${lk_proxy_image_key}"
		lk_proxy_image_var="HOOK_CONTAINER_LINUXKIT_$(echo "${lk_proxy_image_key}" | tr '[:lower:]' '[:upper:]')_IMAGE"
		log info "Preparing LinuxKit proxy image ${lk_proxy_image_ref} in ${lk_proxy_image_dir}, variable name ${lk_proxy_image_var}"
		rm -rf "images/${lk_proxy_image_dir}"
		mkdir -p "images/${lk_proxy_image_dir}"
		if [[ "${DOCKER_ARCH}" == "loong64" ]]; then
			write_loong64_linuxkit_package_dockerfile "${lk_proxy_image_key}" "${lk_proxy_image_dir}"
		else
			echo "FROM --platform=\${TARGETARCH} ${lk_proxy_image_ref}" > "images/${lk_proxy_image_dir}/Dockerfile"
		fi
		build_hook_linuxkit_container "${lk_proxy_image_dir}" "${lk_proxy_image_var}" "${EXPORT_LK_CONTAINERS}" "${EXPORT_LK_CONTAINERS_DIR}"
	done
}

function prepare_loong64_embedded_tink_agent() {
	declare agent_image="${hook_template_vars["HOOK_CONTAINER_TINK_AGENT_IMAGE"]}"
	declare agent_archive="images/hook-embedded/images/tink-agent-loong64.tar"

	log info "Saving ${agent_image} into ${agent_archive} for embedded containerd import"
	mkdir -p "$(dirname "${agent_archive}")"
	docker save -o "${agent_archive}" "${agent_image}"
}

function write_loong64_linuxkit_package_dockerfile() {
	declare package_key="${1}"
	declare package_dir="${2}"
	declare dockerfile_path="images/${package_dir}/Dockerfile"

	case "${package_key}" in
		init)
			cat > "${dockerfile_path}" <<'LOONG64_INIT_DOCKERFILE'
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
ENV GO_VERSION=1.24.5
ENV LINUXKIT_VERSION=v1.8.2
ENV CONTAINERD_VERSION=v2.1.3
ENV BUSYBOX_VERSION=1.36.1
ENV PATH=/usr/local/go/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
  bzip2 ca-certificates curl file gcc git libc6-dev make xz-utils \
  gcc-loongarch64-linux-gnu libc6-dev-loong64-cross \
  && rm -rf /var/lib/apt/lists/*
RUN build_arch="$(dpkg --print-architecture)" && \
  case "${build_arch}" in amd64) go_arch=amd64 ;; arm64) go_arch=arm64 ;; *) echo "unsupported build architecture ${build_arch}" >&2; exit 1 ;; esac && \
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" | tar -C /usr/local -xz
RUN git clone --depth 1 --branch "${LINUXKIT_VERSION}" https://github.com/linuxkit/linuxkit.git /src/linuxkit && \
  git clone --depth 1 --branch "${CONTAINERD_VERSION}" https://github.com/containerd/containerd.git /src/containerd && \
  curl -fsSL "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && \
  tar -C /tmp -xjf /tmp/busybox.tar.bz2
WORKDIR /tmp/busybox-${BUSYBOX_VERSION}
RUN make defconfig && \
  for symbol in STATIC ASH SH_IS_ASH INIT FEATURE_USE_INITTAB MOUNT UMOUNT MKNOD MODPROBE INSMOD RMMOD LSMOD MDEV FEATURE_MDEV_CONF FEATURE_MDEV_EXEC FEATURE_MDEV_DAEMON IFUP IFDOWN FEATURE_IFUPDOWN_IP FEATURE_IFUPDOWN_IPV4 GETTY LOGIN NTPD UDHCPC IP ROUTE IFCONFIG FEATURE_IFCONFIG_STATUS FEATURE_UDHCPC_ARPING FEATURE_UDHCPC_SANITIZEOPT HWCLK LS PS TAIL OD GREP WC TRUE FALSE; do \
    sed -i "s/^# CONFIG_${symbol} is not set/CONFIG_${symbol}=y/" .config; \
    sed -i "s/^CONFIG_${symbol}=.*/CONFIG_${symbol}=y/" .config; \
    grep -q "^CONFIG_${symbol}=y$" .config || echo "CONFIG_${symbol}=y" >> .config; \
  done && \
  sed -i "s/^CONFIG_TC=.*/# CONFIG_TC is not set/" .config && \
  yes "" | make oldconfig && \
  make -j"$(nproc)" CROSS_COMPILE=loongarch64-linux-gnu- busybox && \
  file busybox
WORKDIR /src/linuxkit/pkg/init
RUN CC=loongarch64-linux-gnu-gcc CFLAGS="-Werror" LDFLAGS="-static" make usermode-helper && file usermode-helper
RUN cd /src/linuxkit/pkg/init/cmd/service && ./skanky-vendor.sh /src/containerd
RUN GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/init ./cmd/init && \
  GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/rc.init ./cmd/rc.init && \
  GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/service && \
  file /out/init /out/rc.init /out/service
RUN mkdir -p /stage/bin /stage/sbin /stage/usr/bin /stage/etc/init.d /stage/etc/ssl/certs /stage/dev /stage/proc /stage/run /stage/sys /stage/sys/fs/cgroup /stage/tmp /stage/var /stage/mnt /stage/root && \
  chmod 1777 /stage/tmp && \
  chmod 0700 /stage/root && \
  cp /out/init /stage/init && \
  cp /out/service /stage/usr/bin/service && \
  cp /out/rc.init /stage/bin/rc.init && \
  cp usermode-helper /stage/sbin/usermode-helper && \
  cp /tmp/busybox-${BUSYBOX_VERSION}/busybox /stage/bin/busybox && \
  cp -a etc/. /stage/etc/ && \
  ln -s rc.init /stage/bin/rc.shutdown && \
  ln -s /bin/busybox /stage/sbin/init && \
  ln -s /usr/bin/service /stage/etc/init.d/005-volumes && \
  for app in sh init mount umount mknod mkdir rmdir ln cp mv rm chmod chown cat echo sleep ps kill grep sed awk cut date find stat dmesg switch_root modprobe insmod rmmod lsmod mdev ifup ifdown ip route ifconfig udhcpc ntpd getty login hwclock ls tail od wc true false; do ln -s /bin/busybox "/stage/bin/${app}" || true; done && \
  mkdir -p /stage/sbin /stage/usr/sbin && \
  for app in modprobe insmod rmmod mdev ifup ifdown udhcpc hwclock; do ln -sf /bin/busybox "/stage/sbin/${app}"; done && \
  ln -sf /bin/busybox /stage/usr/sbin/ntpd && \
  echo 'root:x:0:0:root:/root:/bin/sh' > /stage/etc/passwd && \
  echo 'root:x:0:' > /stage/etc/group
FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=builder /stage/ /
LOONG64_INIT_DOCKERFILE
			;;
		ca_certificates)
			cat > "${dockerfile_path}" <<'LOONG64_CA_DOCKERFILE'
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
FROM scratch
ENTRYPOINT []
WORKDIR /
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
LOONG64_CA_DOCKERFILE
			;;
		firmware)
			cat > "${dockerfile_path}" <<'LOONG64_FIRMWARE_DOCKERFILE'
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder
RUN mkdir -p /out/lib/firmware && \
  printf 'LoongArch HookOS firmware placeholder. Add board-specific firmware here when required.\n' > /out/lib/firmware/README.hook
FROM scratch
ENTRYPOINT []
WORKDIR /
COPY --from=builder /out/lib/ /lib/
LOONG64_FIRMWARE_DOCKERFILE
			;;
		rngd)
			cat > "${dockerfile_path}" <<'LOONG64_RNGD_DOCKERFILE'
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive
ENV BUSYBOX_VERSION=1.36.1
RUN apt-get update && apt-get install -y --no-install-recommends bzip2 ca-certificates curl file gcc libc6-dev make gcc-loongarch64-linux-gnu libc6-dev-loong64-cross && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && tar -C /tmp -xjf /tmp/busybox.tar.bz2
WORKDIR /tmp/busybox-${BUSYBOX_VERSION}
RUN make defconfig && \
  for symbol in STATIC ASH SH_IS_ASH SLEEP; do \
    sed -i "s/^# CONFIG_${symbol} is not set/CONFIG_${symbol}=y/" .config; \
    sed -i "s/^CONFIG_${symbol}=.*/CONFIG_${symbol}=y/" .config; \
    grep -q "^CONFIG_${symbol}=y$" .config || echo "CONFIG_${symbol}=y" >> .config; \
  done && \
  sed -i "s/^CONFIG_TC=.*/# CONFIG_TC is not set/" .config && \
  yes "" | make oldconfig && \
  make -j"$(nproc)" CROSS_COMPILE=loongarch64-linux-gnu- busybox && file busybox
RUN mkdir -p /stage/bin /stage/sbin && \
  cp busybox /stage/bin/busybox && \
  ln -s /bin/busybox /stage/bin/sh && \
  ln -s /bin/busybox /stage/bin/sleep
COPY rngd.sh /stage/sbin/rngd
RUN chmod 0755 /stage/sbin/rngd
FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=builder /stage/ /
CMD ["/sbin/rngd"]
LOONG64_RNGD_DOCKERFILE
			cat > "images/${package_dir}/rngd.sh" <<'LOONG64_RNGD_SCRIPT'
#!/bin/sh
if [ "${1:-}" = "-1" ]; then
	exit 0
fi
while :; do
	sleep 3600
done
LOONG64_RNGD_SCRIPT
			chmod +x "images/${package_dir}/rngd.sh"
			;;
		sysctl)
			cat > "${dockerfile_path}" <<'LOONG64_SYSCTL_DOCKERFILE'
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
RUN apk add --no-cache git
RUN git clone --depth 1 --branch v1.8.2 https://github.com/linuxkit/linuxkit.git /src/linuxkit
WORKDIR /src/linuxkit/pkg/sysctl
RUN GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/sysctl .
FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=builder /out/sysctl /usr/bin/sysctl
COPY --from=builder /src/linuxkit/pkg/sysctl/etc/ /etc/
CMD ["/usr/bin/sysctl"]
LOONG64_SYSCTL_DOCKERFILE
			;;
		sysfs)
			cat > "${dockerfile_path}" <<'LOONG64_SYSFS_DOCKERFILE'
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
RUN apk add --no-cache git
RUN git clone --depth 1 --branch v1.8.2 https://github.com/linuxkit/linuxkit.git /src/linuxkit
WORKDIR /src/linuxkit/pkg/sysfs
RUN GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/sysfs .
FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=builder /out/sysfs /usr/bin/sysfs
COPY --from=builder /src/linuxkit/pkg/sysfs/etc/ /etc/
CMD ["/usr/bin/sysfs"]
LOONG64_SYSFS_DOCKERFILE
			;;
		modprobe)
			write_loong64_busybox_package_dockerfile "${dockerfile_path}" "modprobe" "/sbin/modprobe"
			;;
		openntpd)
			write_loong64_busybox_package_dockerfile "${dockerfile_path}" "openntpd" "/usr/sbin/ntpd -d"
			;;
		getty)
			write_loong64_getty_package "${package_dir}" "${dockerfile_path}"
			;;
		dhcpcd)
			write_loong64_dhcpcd_package "${package_dir}" "${dockerfile_path}"
			;;
		sshd)
			write_loong64_busybox_package_dockerfile "${dockerfile_path}" "sshd" "/bin/sh"
			;;
		*) log error "No loong64 LinuxKit package replacement for ${package_key}" && exit 10 ;;
	esac
}

function write_loong64_busybox_package_dockerfile() {
	declare dockerfile_path="${1}"
	declare package_name="${2}"
	cat > "${dockerfile_path}" <<LOONG64_BUSYBOX_DOCKERFILE
FROM --platform=\$BUILDPLATFORM debian:trixie-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive
ENV BUSYBOX_VERSION=1.36.1
RUN apt-get update && apt-get install -y --no-install-recommends bzip2 ca-certificates curl file gcc libc6-dev make gcc-loongarch64-linux-gnu libc6-dev-loong64-cross && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://busybox.net/downloads/busybox-\${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && tar -C /tmp -xjf /tmp/busybox.tar.bz2
WORKDIR /tmp/busybox-\${BUSYBOX_VERSION}
RUN make defconfig && \
  for symbol in STATIC ASH SH_IS_ASH MODPROBE INSMOD RMMOD LSMOD NTPD SLEEP UDHCPC IP ROUTE IFCONFIG MKDIR CAT ECHO GETTY SED DATE STAT FEATURE_STAT_FORMAT CUT LS PS TAIL OD GREP WC TRUE FALSE; do \
    sed -i "s/^# CONFIG_\${symbol} is not set/CONFIG_\${symbol}=y/" .config; \
    sed -i "s/^CONFIG_\${symbol}=.*/CONFIG_\${symbol}=y/" .config; \
    grep -q "^CONFIG_\${symbol}=y$" .config || echo "CONFIG_\${symbol}=y" >> .config; \
  done && \
  sed -i "s/^CONFIG_TC=.*/# CONFIG_TC is not set/" .config && \
  yes "" | make oldconfig && \
  make -j"\$(nproc)" CROSS_COMPILE=loongarch64-linux-gnu- busybox && file busybox
RUN mkdir -p /stage/bin /stage/sbin /stage/usr/bin /stage/usr/sbin /stage/usr/share/udhcpc && cp busybox /stage/bin/busybox && \
  for app in sh sleep modprobe insmod rmmod lsmod ntpd udhcpc ip route ifconfig mkdir cat echo getty sed date stat cut ls ps tail od grep wc true false; do ln -s /bin/busybox "/stage/bin/\${app}" || true; done && \
  for app in modprobe insmod rmmod lsmod; do ln -s /bin/busybox "/stage/sbin/\${app}" || true; done && \
  ln -s /bin/busybox /stage/usr/sbin/ntpd
FROM scratch
ENTRYPOINT []
WORKDIR /
COPY --from=builder /stage/ /
LOONG64_BUSYBOX_DOCKERFILE
	# The generic CMD above is only a placeholder; LinuxKit service commands override it.
	case "${package_name}" in
		openntpd) echo 'CMD ["/usr/sbin/ntpd", "-d"]' >> "${dockerfile_path}" ;;
		modprobe) echo 'CMD ["/sbin/modprobe"]' >> "${dockerfile_path}" ;;
		getty) echo 'CMD ["/usr/bin/rungetty.sh"]' >> "${dockerfile_path}" ;;
		dhcpcd) echo 'CMD ["/sbin/dhcpcd"]' >> "${dockerfile_path}" ;;
		*) echo 'CMD ["/bin/sh"]' >> "${dockerfile_path}" ;;
	esac
}

function write_loong64_getty_package() {
	declare package_dir="${1}"
	declare dockerfile_path="${2}"
	write_loong64_busybox_package_dockerfile "${dockerfile_path}" "getty" "/usr/bin/rungetty.sh"
	cat >> "${dockerfile_path}" <<'LOONG64_GETTY_APPEND'
COPY rungetty.sh /usr/bin/rungetty.sh
LOONG64_GETTY_APPEND
	cat > "images/${package_dir}/rungetty.sh" <<'LOONG64_GETTY_SCRIPT'
#!/bin/sh
exec /bin/getty -n -l /bin/sh -L console 115200 vt100
LOONG64_GETTY_SCRIPT
	chmod +x "images/${package_dir}/rungetty.sh"
}

function write_loong64_dhcpcd_package() {
	declare package_dir="${1}"
	declare dockerfile_path="${2}"
	write_loong64_busybox_package_dockerfile "${dockerfile_path}" "dhcpcd" "/sbin/dhcpcd"
	cat >> "${dockerfile_path}" <<'LOONG64_DHCPCD_APPEND'
COPY dhcpcd.sh /sbin/dhcpcd
COPY udhcpc.script /usr/share/udhcpc/default.script
LOONG64_DHCPCD_APPEND
cat > "images/${package_dir}/dhcpcd.sh" <<'LOONG64_DHCPCD_SCRIPT'
#!/bin/sh
oneshot=false
foreground=true
allowinterfaces="e*"
while [ "$#" -gt 0 ]; do
	case "$1" in
		-1) oneshot=true ;;
		--nobackground) foreground=true ;;
		--allowinterfaces) shift; allowinterfaces="${1:-e*}" ;;
	esac
	shift || true
done
iface=""
for candidate in /sys/class/net/$allowinterfaces /sys/class/net/e* /sys/class/net/en* /sys/class/net/eth*; do
	[ -e "$candidate" ] || continue
	name="${candidate##*/}"
	[ "$name" = "lo" ] && continue
	iface="$name"
	break
done
args="-f -s /usr/share/udhcpc/default.script"
[ -n "$iface" ] && args="$args -i $iface"
if [ "$oneshot" = true ]; then
	exec /bin/udhcpc -q -t 5 $args
fi
exec /bin/udhcpc $args
LOONG64_DHCPCD_SCRIPT
	cat > "images/${package_dir}/udhcpc.script" <<'LOONG64_UDHCPC_SCRIPT'
#!/bin/sh
[ -n "$interface" ] || exit 0
case "$1" in
	bound|renew)
		/bin/ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up 2>/dev/null || true
		[ -n "$router" ] && for r in $router; do /bin/route add default gw "$r" dev "$interface" 2>/dev/null || true; break; done
		if [ -n "$dns" ]; then
			mkdir -p /etc /run/resolvconf
			: > /etc/resolv.conf
			: > /run/resolvconf/resolv.conf
			for ns in $dns; do
				echo "nameserver $ns" >> /etc/resolv.conf
				echo "nameserver $ns" >> /run/resolvconf/resolv.conf
			done
		fi
		;;
	deconfig)
		/bin/ifconfig "$interface" 0.0.0.0 2>/dev/null || true
		;;
esac
LOONG64_UDHCPC_SCRIPT
	chmod +x "images/${package_dir}/dhcpcd.sh" "images/${package_dir}/udhcpc.script"
}

function build_hook_linuxkit_container() {
	declare container_dir="${1}"
	declare template_var="${2}" # bash name reference, kind of an output var but weird
	declare container_base_dir="images"
	declare export_container_images="${3:-false}"
	declare export_container_images_dir="${4:-/tmp}"

	# Lets hash the contents of the directory and use that as a tag
	declare container_files_hash
	# NOTE: linuxkit containers must be in the images/ directory
	container_files_hash="$(find "${container_base_dir}/${container_dir}" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
	declare container_files_hash_short="${container_files_hash:0:8}"

	declare container_oci_ref="${HOOK_LK_CONTAINERS_OCI_BASE}${container_dir}:${container_files_hash_short}-${DOCKER_ARCH}"
	log info "Consider building LK container ${container_oci_ref} from ${container_base_dir}/${container_dir} for platform ${DOCKER_ARCH}"
	hook_template_vars["${template_var}"]="${container_oci_ref}" # set the template var for envsubst

	# If the image is in the local docker cache, skip building
	log debug "Checking if image ${container_oci_ref} exists in local registry"
	if [[ -n "$(docker images -q "${container_oci_ref}")" ]]; then
		log info "Image ${container_oci_ref} exists in local registry, skipping build"
		# we try to push here because a previous build may have created the image
		# this is the case for GitHub Actions CI because we build PRs on the same self-hosted runner
		push_hook_linuxkit_container "${container_oci_ref}"

		# If export_container_images=yes then export images as tar.gzs to export_container_images_dir
		# This is mainly for CI to be able to pass built images between jobs
		if [[ "${export_container_images}" == "yes" ]]; then
			save_docker_image_to_tar_gz "${container_oci_ref}" "${export_container_images_dir}"
		fi
		return 0
	fi

	# Check if we can pull the image from registry; if so, skip the build.
	log debug "Checking if image ${container_oci_ref} can be pulled from remote registry"
	if docker pull "${container_oci_ref}"; then
		log info "Image ${container_oci_ref} pulled from remote registry, skipping build"
		# If export_container_images=yes then export images as tar.gzs to export_container_images_dir
		# This is mainly for CI to be able to pass built images between jobs
		if [[ "${export_container_images}" == "yes" ]]; then
			save_docker_image_to_tar_gz "${container_oci_ref}" "${export_container_images_dir}"
		fi
		return 0
	fi

	# If environment DO_BUILD_LK_CONTAINERS=no, we're being asked NOT to build this. Exit with an error.
	if [[ "${DO_BUILD_LK_CONTAINERS}" == "no" ]]; then
		log error "DO_BUILD_LK_CONTAINERS is set to 'no'; not building ${container_oci_ref}"
		exit 9
	fi

	log info "Building ${container_oci_ref} from ${container_base_dir}/${container_dir} for platform ${DOCKER_ARCH}"
	(
		cd "${container_base_dir}/${container_dir}" || exit 1
		docker buildx build --load "--progress=${DOCKER_BUILDX_PROGRESS_TYPE}" -t "${container_oci_ref}" --platform "linux/${DOCKER_ARCH}" .
	)

	log info "Built ${container_oci_ref} from ${container_base_dir}/${container_dir} for platform ${DOCKER_ARCH}"

	push_hook_linuxkit_container "${container_oci_ref}"

	# If export_container_images=yes then export images as tar.gzs to export_container_images_dir
	# This is mainly for CI to be able to pass built images between jobs
	if [[ "${export_container_images}" == "yes" ]]; then
		save_docker_image_to_tar_gz "${container_oci_ref}" "${export_container_images_dir}"
	fi

	return 0
}

function save_docker_image_to_tar_gz() {
	declare container_oci_ref="${1}"
	declare export_dir="${2:-/tmp}"

	# Create the export directory if it doesn't exist
	mkdir -p "${export_dir}"

	# Save the Docker image as a tar.gz file
	docker save "${container_oci_ref}" | gzip > "${export_dir}/$(basename "${container_oci_ref}" | sed 's/:/-/g').tar.gz"
	log info "Saved Docker image ${container_oci_ref} to ${export_dir}/$(basename "${container_oci_ref}" | sed 's/:/-/g').tar.gz"
}

function push_hook_linuxkit_container() {
	declare container_oci_ref="${1}"

	# Push the image to the registry, if DO_PUSH is set to yes
	if [[ "${DO_PUSH}" == "yes" ]]; then
		docker push "${container_oci_ref}" || {
			log error "Failed to push ${container_oci_ref} to registry"
			exit 33
		}
	else
		log info "Skipping push of ${container_oci_ref} to registry; set DO_PUSH=yes to push."
	fi
}
