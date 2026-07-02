#!/usr/bin/env bash

function list_bootable_direct_efi() {
	: "${bootable_info['BOOTABLE_ID']:?"bootable_info['BOOTABLE_ID'] is unset"}"
	declare -g -A bootable_boards=()
	declare board_name="${bootable_info['BOOTABLE_ID']}-generic"
	bootable_boards["${board_name}"]="NOT=used"
}

function build_bootable_direct_efi() {
	: "${kernel_info['DOCKER_ARCH']:?"kernel_info['DOCKER_ARCH'] is unset"}"
	: "${bootable_info['INVENTORY_ID']:?"bootable_info['INVENTORY_ID'] is unset"}"
	: "${OUTPUT_ID:?"OUTPUT_ID is unset"}"

	if [[ "${kernel_info['DOCKER_ARCH']}" != "loong64" ]]; then
		log error "direct_efi bootable media is currently only implemented for loong64"
		exit 66
	fi

	if [[ -z "${kernel_oci_image:-}" ]]; then
		kernel_calculate_version
	fi

	declare hook_id="${bootable_info['INVENTORY_ID']}"
	declare bootable_dir="direct-efi-loongarch64"
	declare bootable_base_dir="bootable/${bootable_dir}"
	declare bootable_img="bootable_direct_efi_${OUTPUT_ID}.img"
	declare fat32_root_dir="${bootable_base_dir}/fat32-root"
	declare fat32_efi_dir="${fat32_root_dir}/EFI/BOOT"

	log info "Building direct EFI bootable media for hook ${hook_id}"

	rm -rf "${bootable_base_dir}"
	mkdir -p "${fat32_efi_dir}"

	install_direct_efi_grub "${fat32_root_dir}"
	install_direct_efi_kernel "${fat32_root_dir}"
	install_direct_efi_initrd "${fat32_root_dir}"
	write_direct_efi_grub_config "${fat32_root_dir}"

	log_tree "${bootable_base_dir}" "debug" "State of the direct EFI bootable directory"

	create_direct_efi_image_fat32_root_from_dir "${bootable_base_dir}" "${bootable_img}" "${fat32_root_dir}"

	log info "Done building direct EFI bootable media for hook ${hook_id}"
	mkdir -p out
	output_bootable_media "${bootable_base_dir}/${bootable_img}" "hook-bootable-direct-efi-${OUTPUT_ID}"
}

function install_direct_efi_kernel() {
	declare fat32_root_dir="${1}"
	declare built_kernel_path="out/hook/vmlinuz-${OUTPUT_ID}"

	if [[ -f "${built_kernel_path}" ]]; then
		log info "Using existing kernel artifact ${built_kernel_path}"
		cp -p "${debug_dash_v[@]}" "${built_kernel_path}" "${fat32_root_dir}/vmlinuz"
		return 0
	fi

	log info "No ${built_kernel_path}; extracting /kernel from ${kernel_oci_image}"
	declare container_name="export-kernel-${OUTPUT_ID}-${RANDOM}"
	docker create --platform "linux/${kernel_info['DOCKER_ARCH']}" --name "${container_name}" "${kernel_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	docker export "${container_name}" | tar -xO "kernel" > "${fat32_root_dir}/vmlinuz"
	docker rm "${container_name}"
}

function install_direct_efi_grub() {
	declare fat32_root_dir="${1}"
	declare fat32_efi_dir="${fat32_root_dir}/EFI/BOOT"
	mkdir -p "${fat32_efi_dir}"

	declare grub_cache_dir="${CACHE_DIR}/grub-loongarch64-efi"
	declare grub_efi="${grub_cache_dir}/grubloongarch64.efi"
	if [[ ! -f "${grub_efi}" ]]; then
		log info "Downloading Debian Ports GRUB loongarch64 EFI image"
		mkdir -p "${grub_cache_dir}"
		declare grub_tmp
		grub_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hook-grub-loongarch64.XXXXXX")"
		curl -fsSL "http://ftp.ports.debian.org/debian-ports/dists/sid/main/binary-loong64/Packages.xz" -o "${grub_tmp}/Packages.xz"
		declare package_filename
		package_filename="$(
			xz -dc "${grub_tmp}/Packages.xz" |
				awk 'BEGIN{p=0; f=""} /^Package: grub-efi-loong64-unsigned$/{p=1} p && /^Filename:/{f=$2; p=0} END{print f}'
		)"
		if [[ -z "${package_filename}" ]]; then
			log error "Could not find grub-efi-loong64-unsigned in Debian Ports package metadata"
			exit 69
		fi
		curl -fsSL "http://ftp.ports.debian.org/debian-ports/${package_filename}" -o "${grub_tmp}/grub-efi-loong64-unsigned.deb"
		(
			cd "${grub_tmp}" || exit 1
			ar x grub-efi-loong64-unsigned.deb
			mkdir data
			tar -C data -xf data.tar.*
		)
		cp -p "${grub_tmp}/data/usr/lib/grub/loongarch64-efi/monolithic/grubloongarch64.efi" "${grub_efi}"
		rm -rf "${grub_tmp}"
	fi

	cp -p "${debug_dash_v[@]}" "${grub_efi}" "${fat32_efi_dir}/BOOTLOONGARCH64.EFI"
}

function write_direct_efi_grub_config() {
	declare fat32_root_dir="${1}"
	declare -g -a bootable_tinkerbell_kernel_params=()
	fill_array_bootable_tinkerbell_kernel_parameters "efi-loong64"
	declare tinkerbell_args="${bootable_tinkerbell_kernel_params[*]}"
	declare grub_cfg
	grub_cfg="$(mktemp "${TMPDIR:-/tmp}/hook-direct-efi-grub.XXXXXX")"
	cat > "${grub_cfg}" <<- GRUB_CFG
		set timeout=0
		set default=0
		terminal_output console
		menuentry 'HookOS loongarch64' {
		  linux /vmlinuz console=ttyS0 ${tinkerbell_args}
		  initrd /initrd.img
		}
	GRUB_CFG

	# Debian's monolithic GRUB image uses the vendor path; the other copies
	# keep the image usable if a future GRUB build uses the removable path.
	mkdir -p "${fat32_root_dir}/EFI/debian" "${fat32_root_dir}/EFI/BOOT" "${fat32_root_dir}/boot/grub"
	cp -p "${debug_dash_v[@]}" "${grub_cfg}" "${fat32_root_dir}/EFI/debian/grub.cfg"
	cp -p "${debug_dash_v[@]}" "${grub_cfg}" "${fat32_root_dir}/EFI/BOOT/grub.cfg"
	cp -p "${debug_dash_v[@]}" "${grub_cfg}" "${fat32_root_dir}/boot/grub/grub.cfg"
	rm -f "${grub_cfg}"
}

function create_direct_efi_image_fat32_root_from_dir() {
	declare output_dir="${1}"
	declare output_filename="${2}"
	declare fat32_root_dir="${3}"
	declare output_image="${output_dir}/${output_filename}"

	if [[ "$(uname -s)" == "Darwin" ]] && command -v hdiutil >/dev/null 2>&1 && command -v newfs_msdos >/dev/null 2>&1; then
		create_direct_efi_image_fat32_root_from_dir_darwin "${output_image}" "${fat32_root_dir}"
		return 0
	fi

	log warn "Falling back to Docker FAT32 image creation; local hdiutil/newfs_msdos path is unavailable."
	esp_partitition="yes" create_image_fat32_root_from_dir "${output_dir}" "${output_filename}" "${fat32_root_dir}"
}

function create_direct_efi_image_fat32_root_from_dir_darwin() {
	declare output_image="${1}"
	declare fat32_root_dir="${2}"
	declare mount_dir=""
	declare image_dev=""
	declare image_size_mb=96
	declare source_size_mb
	source_size_mb="$(du -sm "${fat32_root_dir}" | awk '{print $1}')"
	if (( source_size_mb + 64 > image_size_mb )); then
		image_size_mb=$((source_size_mb + 64))
	fi

	log info "Creating local FAT32 removable EFI image '${output_image}' (${image_size_mb} MiB) from '${fat32_root_dir}'"
	rm -f "${output_image}"
	truncate -s "${image_size_mb}m" "${output_image}"

	image_dev="$(hdiutil attach -nomount "${output_image}" | awk 'NR==1{print $1}')"
	newfs_msdos -F 32 -v HOOK "${image_dev}" >/dev/null
	hdiutil detach "${image_dev}" >/dev/null
	image_dev=""

	mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/hook-direct-efi-mount.XXXXXX")"
	hdiutil attach "${output_image}" -mountpoint "${mount_dir}" -nobrowse >/dev/null
	COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 cp -R "${fat32_root_dir}/." "${mount_dir}/"
	find "${mount_dir}" -name '._*' -delete
	sync
	hdiutil detach "${mount_dir}" >/dev/null
	rmdir "${mount_dir}"

	declare fat32img_size
	fat32img_size="$(du -h "${output_image}" | cut -f 1)"
	log info "Built direct EFI FAT32 image '${output_image}' (${fat32img_size})"
}

function install_direct_efi_initrd() {
	declare fat32_root_dir="${1}"
	declare built_initrd_path="out/hook/initramfs-${OUTPUT_ID}"

	if [[ -f "${built_initrd_path}" ]]; then
		log info "Using existing initrd artifact ${built_initrd_path}"
		cp -p "${debug_dash_v[@]}" "${built_initrd_path}" "${fat32_root_dir}/initrd.img"
		return 0
	fi

	log warn "No ${built_initrd_path}; building a minimal loong64 initrd instead of a full Hook LinuxKit initrd."
	build_minimal_loongarch_initrd "${fat32_root_dir}/initrd.img"
}

function build_minimal_loongarch_initrd() {
	declare output_initrd="${1}"
	declare initrd_build_dir="bootable/direct-efi-initrd"
	rm -rf "${initrd_build_dir}"
	mkdir -p "${initrd_build_dir}"

	cat <<- 'INIT_GO' > "${initrd_build_dir}/init.go"
		package main

		import (
			"fmt"
			"os"
			"syscall"
			"time"
		)

		func mount(source, target, fstype string, flags uintptr, data string) {
			if err := os.MkdirAll(target, 0755); err != nil {
				fmt.Printf("mkdir %s: %v\n", target, err)
				return
			}
			if err := syscall.Mount(source, target, fstype, flags, data); err != nil {
				fmt.Printf("mount %s on %s: %v\n", fstype, target, err)
			}
		}

		func main() {
			fmt.Println("hookOS loongarch64 direct EFI initrd")
			mount("proc", "/proc", "proc", 0, "")
			mount("sysfs", "/sys", "sysfs", 0, "")
			mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")
			mount("tmpfs", "/run", "tmpfs", 0, "mode=0755")
			if cmdline, err := os.ReadFile("/proc/cmdline"); err == nil {
				fmt.Printf("cmdline: %s\n", cmdline)
			}
			fmt.Println("Full Hook LinuxKit userspace is not available for loong64 yet; this image verifies kernel and EFI boot.")
			for {
				time.Sleep(time.Hour)
			}
		}
	INIT_GO

	log info "Building minimal loong64 initrd at ${output_initrd}"
	if ! command -v go >/dev/null 2>&1; then
		log error "go is required to build the minimal loong64 direct-EFI initrd fallback"
		exit 67
	fi
	if ! command -v cpio >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
		log error "cpio and gzip are required to build the minimal loong64 direct-EFI initrd fallback"
		exit 68
	fi

	declare rootfs_dir="${initrd_build_dir}/rootfs"
	mkdir -p "${rootfs_dir}/dev" "${rootfs_dir}/proc" "${rootfs_dir}/sys" "${rootfs_dir}/run" "${rootfs_dir}/tmp" "${rootfs_dir}/etc"
	GOOS=linux GOARCH=loong64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${rootfs_dir}/init" "${initrd_build_dir}/init.go"
	printf 'NAME="hookOS loongarch64 direct EFI"\n' > "${rootfs_dir}/etc/os-release"
	(
		cd "${rootfs_dir}" || exit 1
		find . -print | cpio -o --format=newc | gzip -9 > "../initrd.img"
	)
	mv "${initrd_build_dir}/initrd.img" "${output_initrd}"
}
