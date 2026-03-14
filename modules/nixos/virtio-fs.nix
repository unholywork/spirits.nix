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

  config.fileSystems = lib.mapAttrs' (
    tag: share:
    lib.nameValuePair share.mountPoint {
      device = tag;
      fsType = "virtiofs";
      options = if share.readOnly then [ "ro" ] else [ "defaults" ];
    }
  ) cfg.sharedDirectories;
}
