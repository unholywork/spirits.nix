{
  name,
  nixosConfig,
  hostPkgs,
  spiritBin,
}:

let
  lib = hostPkgs.lib;
  linuxPkgs = nixosConfig.pkgs;
  cfg = nixosConfig.config;
  spiritsCfg = cfg.spirit;
  toplevel = cfg.system.build.toplevel;
  kernelPath = "${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile}";
  initrdPath = "${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}";

  # Read-only store image containing the system closure. Mounted in the guest
  # as a virtio-blk disk instead of sharing /nix/store via virtio-fs, which
  # avoids the multi-VM contention on Apple's virtio-fs implementation.
  storeImage = linuxPkgs.callPackage (linuxPkgs.path + "/nixos/lib/make-squashfs.nix") {
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level 6";
  };

  kernelParams = builtins.concatStringsSep " " (
    cfg.boot.kernelParams
    ++ [
      "init=${toplevel}/init"
    ]
  );

  sharedDirs = spiritsCfg.sharedDirectories;

  hasEphemeralDisk = spiritsCfg.ephemeralDisk.enable;
  ephemeralDisk = spiritsCfg.ephemeralDisk;

  hasDisk = spiritsCfg.disk.enable;
  disk = spiritsCfg.disk;
  stateDir = spiritsCfg.stateDir;
  netCfg = spiritsCfg.networking;
  bridged = netCfg.mode == "bridged";

  ephemeralDiskSetup = lib.optionalString hasEphemeralDisk ''
    EPHEMERAL_DISK="''${TMPDIR:-/tmp}/spirit-${name}.img"
    rm -f "$EPHEMERAL_DISK"
    truncate -s ${toString ephemeralDisk.sizeMiB}M "$EPHEMERAL_DISK"
  '';

  diskSetup = lib.optionalString hasDisk ''
    DISK_PATH="${disk.hostPath}"
    if [ ! -f "$DISK_PATH" ]; then
      echo "Creating disk image at $DISK_PATH (${toString disk.hostSizeMiB} MiB)..." >&2
      truncate -s ${toString disk.hostSizeMiB}M "$DISK_PATH"
    fi
  '';

  stateSetup = lib.optionalString (stateDir != null) ''
    mkdir -p "${stateDir}"
    if [ -f "${stateDir}/spirit.vzvmsave" ]; then
      RESTORE_ARGS=("--restore-state" "${stateDir}/spirit.vzvmsave")
    else
      RESTORE_ARGS=()
    fi
  '';
in
hostPkgs.writeShellApplication {
  inherit name;
  text = ''
    ${ephemeralDiskSetup}
    ${diskSetup}
    ${stateSetup}
    CMD=(
      ${spiritBin}
      --kernel ${kernelPath}
      --initrd ${initrdPath}
      --cmdline "$(printf '%s' ${lib.escapeShellArg kernelParams})"
      --cpus ${toString spiritsCfg.cpus}
      --memory ${toString spiritsCfg.memoryMiB}
      --disk ${storeImage}:ro
      ${lib.concatStringsSep "\n      " (
        lib.mapAttrsToList (
          tag: share:
          "--share ${share.hostPath}:${tag}${lib.optionalString share.readOnly ":ro"}"
        ) sharedDirs
      )}
      ${lib.optionalString hasEphemeralDisk ''--disk "$EPHEMERAL_DISK"''}
      ${lib.optionalString hasDisk ''--disk "$DISK_PATH"''}
      ${lib.optionalString bridged "--bridged-interface ${lib.escapeShellArg netCfg.bridged.interface}"}
      ${lib.optionalString (stateDir != null) ''--save-state "${stateDir}/spirit.vzvmsave"''}
    )
    ${lib.optionalString (stateDir != null) ''CMD+=("''${RESTORE_ARGS[@]}")''}
    CMD+=("$@")
    ${lib.optionalString bridged ''
      # Bridged networking uses vmnet.framework which requires root.
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo "''${CMD[@]}"
      fi
    ''}
    exec "''${CMD[@]}"
  '';
}
