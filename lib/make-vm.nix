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
  #
  # mksquashfs's default behaviour is to log "could not find file: ..., creating
  # empty file" and exit 0 — which silently corrupts the store image. Wrap it
  # so every invocation gets -exit-on-error and those warnings become hard
  # failures instead.
  strictSquashfsTools = linuxPkgs.symlinkJoin {
    name = "squashfs-tools-exit-on-error";
    paths = [ linuxPkgs.squashfs-tools ];
    nativeBuildInputs = [ linuxPkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/mksquashfs --append-flags -exit-on-error
    '';
  };
  storeImage = linuxPkgs.callPackage (linuxPkgs.path + "/nixos/lib/make-squashfs.nix") {
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level 6";
    squashfs-tools = strictSquashfsTools;
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
    EPHEMERAL_DISK="''${TMPDIR:-/tmp}"
    EPHEMERAL_DISK="''${EPHEMERAL_DISK%/}/spirit-${name}.img"
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

  # GC-root the kernel/initrd/squashfs for the VM's lifetime — they reach the
  # spirit binary only as argv strings, which Nix's GC doesn't see as live.
  gcRootSetup = ''
    GCROOT_DIR=$(mktemp -d -t spirit-${name}.XXXXXX)
    trap 'rm -rf "$GCROOT_DIR"' EXIT
    ${hostPkgs.nix}/bin/nix-store --add-root "$GCROOT_DIR/store-image" --indirect --realise ${storeImage} > /dev/null
    ${hostPkgs.nix}/bin/nix-store --add-root "$GCROOT_DIR/kernel" --indirect --realise ${cfg.system.build.kernel} > /dev/null
    ${hostPkgs.nix}/bin/nix-store --add-root "$GCROOT_DIR/initrd" --indirect --realise ${cfg.system.build.initialRamdisk} > /dev/null
  '';
in
hostPkgs.writeShellApplication {
  inherit name;
  text = ''
    ${gcRootSetup}
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
        sudo "''${CMD[@]}"
        exit
      fi
    ''}
    "''${CMD[@]}"
  '';
}
