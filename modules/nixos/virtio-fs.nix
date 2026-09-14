{ config, lib, ... }:

let
  cfg = config.spirit;
in
{
  options.spirit.sharedDirectories = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          hostPath = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path on the host to share.";
          };
          mountPoint = lib.mkOption {
            type = lib.types.str;
            description = "Mount point inside the guest.";
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to mount read-only in the guest.";
          };
        };
      }
    );
    default = { };
    description = "Additional host directories to share with the guest via virtio-fs.";
  };

  config.assertions = lib.mapAttrsToList (tag: _: {
    assertion = !(cfg.store.mode == "shared" && (tag == "nix-store" || tag == "nix-db"));
    message = "spirit.sharedDirectories.${tag}: the tags \"nix-store\" and \"nix-db\" are reserved when spirit.store.mode = \"shared\".";
  }) cfg.sharedDirectories;

  # Virtio-fs is only attached to the VM when something needs it — there is no
  # device to mount otherwise. In the default image mode the store and DB ride a
  # virtio-blk squashfs instead, so with no user shares the whole subtree is gone.
  config.fileSystems =
    lib.optionalAttrs (cfg.sharedDirectories != { } || cfg.store.mode == "shared") {
      # Single virtiofs mount for all host shares, then bind-mount subdirectories.
      # Not mounted ro — individual shares control their own read-only flag via
      # the virtiofs device layer and bind-mount options.
      "/nix/.host" = {
        device = "shares";
        fsType = "virtiofs";
        neededForBoot = true;
      };
    }
    // lib.mapAttrs' (
      tag: share:
      lib.nameValuePair share.mountPoint {
        device = "/nix/.host/${tag}";
        fsType = "none";
        options = [ "bind" ] ++ lib.optional share.readOnly "ro";
        depends = [ "/nix/.host" ];
      }
    ) cfg.sharedDirectories;
}
