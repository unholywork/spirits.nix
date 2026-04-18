{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.spirit;
in
{
  options.spirit = {
    cpus = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of virtual CPUs.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Memory in MiB.";
    };

    networking = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "nat"
          "bridged"
        ];
        default = "nat";
        description = "Networking mode. NAT uses Apple's built-in virtual network; bridged attaches directly to a host interface (requires sudo).";
      };

      nat = {
        staticIP = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Static IP address on the NAT subnet (192.168.64.0/24). Uses DHCP when null.";
        };
      };

      bridged = {
        interface = lib.mkOption {
          type = lib.types.str;
          default = "en0";
          description = "Host network interface to bridge to.";
        };
      };
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host directory for VM save/restore state files.";
    };

    hostKeys = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Path inside the guest where the key is mounted (e.g. from a virtiofs share).";
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "ed25519"
                "rsa"
                "ecdsa"
              ];
              default = "ed25519";
              description = "SSH host key type.";
            };
          };
        }
      );
      default = [ ];
      description = "SSH host keys to install from virtiofs-mounted secrets. Disables auto-generation when set.";
    };

    ephemeralDisk = {
      enable = lib.mkEnableOption "ephemeral root disk (reset on each boot)";
      sizeMiB = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = "Ephemeral disk image size in MiB.";
      };
    };

    disk = {
      enable = lib.mkEnableOption "persistent disk";
      device = lib.mkOption {
        type = lib.types.str;
        default = if cfg.ephemeralDisk.enable then "/dev/vdb" else "/dev/vda";
        defaultText = lib.literalExpression ''if cfg.ephemeralDisk.enable then "/dev/vdb" else "/dev/vda"'';
        description = "Block device path for the persistent disk.";
      };
      fsType = lib.mkOption {
        type = lib.types.str;
        default = "ext4";
        description = "Filesystem type for the persistent disk.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/persist";
        description = "Mount point for the persistent disk.";
      };
      hostPath = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Path to the disk image on the host.";
      };
      hostSizeMiB = lib.mkOption {
        type = lib.types.int;
        default = 65536;
        description = "Disk image size in MiB (created on first run).";
      };
    };
  };

  config = lib.mkMerge [
    # Core guest configuration (always applied)
    {
      # Direct kernel boot — no bootloader needed
      boot.loader.grub.enable = false;

      # Kernel modules required for virtio devices
      boot.initrd.availableKernelModules = [
        "virtio_console"
        "virtiofs"
        "virtio_net"
        "virtio_pci"
        "overlay"
      ];

      # Serial console output
      boot.kernelParams = [ "console=hvc0" ];

      # Stateless root on tmpfs
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "defaults"
          "size=2G"
          "mode=755"
        ];
      };

      # Single virtiofs mount for all host shares, then bind-mount subdirectories.
      # Not mounted ro — individual shares control their own read-only flag via
      # the virtiofs device layer and bind-mount options.
      fileSystems."/nix/.host" = {
        device = "shares";
        fsType = "virtiofs";
        neededForBoot = true;
      };

      # Bind-mount the nix store from the shared virtiofs device
      fileSystems."/nix/.ro-store" = {
        device = "/nix/.host/nix-store";
        fsType = "none";
        options = [ "bind" "ro" ];
        depends = [ "/nix/.host" ];
        neededForBoot = true;
      };

      fileSystems."/nix/.rw-store" = lib.mkIf (!cfg.ephemeralDisk.enable) {
        device = "none";
        fsType = "tmpfs";
        options = [
          "mode=755"
          "size=512M"
        ];
        neededForBoot = true;
      };

      fileSystems."/nix/store" = {
        fsType = "overlay";
        overlay = {
          lowerdir = [ "/nix/.ro-store" ];
          upperdir = "/nix/.rw-store/upper";
          workdir = "/nix/.rw-store/work";
        };
        depends = [
          "/nix/.ro-store"
        ] ++ lib.optional (!cfg.ephemeralDisk.enable) "/nix/.rw-store";
        neededForBoot = true;
      };

      # Bind-mount the nix DB from the shared virtiofs device
      fileSystems."/nix/.ro-db" = {
        device = "/nix/.host/nix-db";
        fsType = "none";
        options = [ "bind" "ro" ];
        depends = [ "/nix/.host" ];
        neededForBoot = true;
      };

      # Copy host DB to writable tmpfs (fast file copy, avoids SQLite locking issues with overlay)
      boot.postBootCommands = ''
        mkdir -p /nix/var/nix/db /nix/var/nix/gcroots /nix/var/nix/profiles /nix/var/nix/userpool
        mkdir -p /nix/var/nix/daemon-socket
        chmod 0755 /nix/var/nix/daemon-socket
        cp /nix/.ro-db/db.sqlite /nix/var/nix/db/db.sqlite
      '';

      # Skip firewall behind NAT for faster boot
      networking.firewall.enable = lib.mkDefault (cfg.networking.mode == "bridged");

      # Networking via systemd-networkd
      networking.useNetworkd = true;
      networking.useDHCP = false;
      systemd.network.enable = true;
      systemd.network.wait-online.enable = false;
    }

    # Networking: DHCP by default
    {
      systemd.network.networks."10-virtio" = {
        matchConfig.Name = "en* eth*";
        networkConfig.DHCP = lib.mkDefault "yes";
        dhcpV4Config.ClientIdentifier = lib.mkDefault "mac";
      };
    }

    # NAT static IP override
    (lib.mkIf (cfg.networking.mode == "nat" && cfg.networking.nat.staticIP != null) {
      systemd.network.networks."10-virtio" = {
        networkConfig = {
          DHCP = lib.mkForce "no";
          Address = [ "${cfg.networking.nat.staticIP}/24" ];
          Gateway = [ "192.168.64.1" ];
          DNS = [ "192.168.64.1" ];
        };
      };
    })

    # SSH host keys from virtiofs-mounted secrets
    (lib.mkIf (cfg.hostKeys != [ ]) {
      # Disable automatic host key generation — we provide our own
      services.openssh.hostKeys = lib.mkForce [ ];
      services.openssh.generateHostKeys = false;

      systemd.services.install-ssh-host-keys = {
        description = "Install SSH host keys from host secrets";
        wantedBy = [ "sshd.service" ];
        before = [ "sshd.service" ];
        serviceConfig.Type = "oneshot";
        script = lib.concatStringsSep "\n" (
          map (
            key:
            let
              dest = "/etc/ssh/ssh_host_${key.type}_key";
            in
            ''
              mkdir -p /etc/ssh
              cp "${key.source}" "${dest}"
              chmod 600 "${dest}"
              if [ ! -f "${dest}.pub" ]; then
                ${pkgs.openssh}/bin/ssh-keygen -y -f "${dest}" > "${dest}.pub"
              fi
            ''
          ) cfg.hostKeys
        );
      };
    })

    # Ephemeral root disk — replaces tmpfs root with a disk image that is reset on each boot
    (lib.mkIf cfg.ephemeralDisk.enable {
      boot.initrd.availableKernelModules = [ "virtio_blk" ];

      boot.initrd.systemd.storePaths = [ "${pkgs.e2fsprogs}/sbin/mke2fs" ];

      # Format the empty disk before fsck/mount runs
      boot.initrd.systemd.services.format-ephemeral-disk = {
        description = "Format ephemeral disk if empty";
        requires = [ "dev-vda.device" ];
        after = [ "dev-vda.device" ];
        requiredBy = [ "sysroot.mount" ];
        before = [ "sysroot.mount" ];
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/etc/initrd-release";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${pkgs.util-linux}/bin/blkid /dev/vda >/dev/null 2>&1; then
            ${pkgs.e2fsprogs}/sbin/mke2fs -t ext4 -q /dev/vda
          fi
        '';
      };

      fileSystems."/" = lib.mkForce {
        device = "/dev/vda";
        fsType = "ext4";
      };
    })

    # Persistent disk
    (lib.mkIf cfg.disk.enable {
      boot.initrd.availableKernelModules = [ "virtio_blk" ];

      boot.initrd.systemd.storePaths = lib.mkIf (cfg.disk.fsType == "ext4") [
        "${pkgs.e2fsprogs}/sbin/mke2fs"
      ];

      # Format a brand new persistent disk image before fsck/mount runs.
      boot.initrd.systemd.services.format-persistent-disk = lib.mkIf (cfg.disk.fsType == "ext4") {
        description = "Format persistent disk if empty";
        requires = [ "${utils.escapeSystemdPath cfg.disk.device}.device" ];
        after = [ "${utils.escapeSystemdPath cfg.disk.device}.device" ];
        requiredBy = [ "initrd-fs.target" ];
        before = [ "initrd-fs.target" ];
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/etc/initrd-release";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${pkgs.util-linux}/bin/blkid ${cfg.disk.device} >/dev/null 2>&1; then
            ${pkgs.e2fsprogs}/sbin/mke2fs -t ext4 -q ${cfg.disk.device}
          fi
        '';
      };

      fileSystems.${cfg.disk.mountPoint} = {
        device = cfg.disk.device;
        fsType = cfg.disk.fsType;
        autoFormat = true;
      };
    })
  ];
}
