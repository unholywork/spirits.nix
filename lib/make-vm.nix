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

  regInfo = linuxPkgs.closureInfo { rootPaths = [ toplevel ]; };

  kernelParams = builtins.concatStringsSep " " (
    cfg.boot.kernelParams
    ++ [
      "init=${toplevel}/init"
      "regInfo=${regInfo}/registration"
    ]
  );

  sharedDirs = spiritsCfg.sharedDirectories;

  hasDisk = spiritsCfg.disk.enable;
  disk = spiritsCfg.disk;
  stateDir = spiritsCfg.stateDir;

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
    ${diskSetup}
    ${stateSetup}
    CMD=(
      ${spiritBin}
      --kernel ${kernelPath}
      --initrd ${initrdPath}
      --cmdline "$(printf '%s' ${lib.escapeShellArg kernelParams})"
      --cpus ${toString spiritsCfg.cpus}
      --memory ${toString spiritsCfg.memoryMiB}
      --share /nix/store:nix-store
      --share /nix/var/nix/db:nix-db
      ${lib.concatStringsSep "\n      " (
        lib.mapAttrsToList (tag: share: "--share ${share.hostPath}:${tag}") sharedDirs
      )}
      ${lib.optionalString hasDisk ''--disk "$DISK_PATH"''}
      ${lib.optionalString (stateDir != null) ''--save-state "${stateDir}/spirit.vzvmsave"''}
    )
    ${lib.optionalString (stateDir != null) ''CMD+=("''${RESTORE_ARGS[@]}")''}
    CMD+=("$@")
    exec "''${CMD[@]}"
  '';
}
