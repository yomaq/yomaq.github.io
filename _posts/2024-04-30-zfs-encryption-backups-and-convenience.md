---
layout: post
title: ZFS, Encryption, Backups, and Convenience
author: yomaq
categories:
- Homelab
- Nixos
tags:
- nixos
- zfs
- tailscale
- backups
date: 2024-04-30 19:45 -0500
---
## Goals

When I began planning out a homelab I had a few expectations for my disk/storage configurations.

1. Easy to setup new devices
2. Convenient backups from any device
3. Convenient restores to any device
4. Encryption with convenient unlocks

## The result
1. Can fully install new systems in about 10 minutes. 
2. Device specific configuration of disks is kept minimal and easily readable.
3. Each system's important files are stored in consistent ZFS datasets which automatically handle snapshots. All files not stored on those specific datasets are removed every reboot, as the root filesystem is destroyed by restoring an empty zfs snapshot.
4. Backup server(s) dynamically create new backup tasks as new machines are added to the Nixos Flake. These backup tasks incrementally replicate a single dataset's snapshots from each machine to the backup computer nightly, stored snapshots are automatically managed.
5. Restoring data to a freshly installed machine is handled by a single command to copy the backed-up zfs dataset to the machine, followed by a nixos-rebuild. 
6. Luks encrypted disks unlocked with initrd-ssh, using a bash script which pulls the passwords from 1password

## Sources
My code examples here were pulled from my current flake repo. If something looks like it doesn't make sense here double check with the flake to see the code that is actually in use and working in my current live environment. All of the links are locked to my last commit at the time I posted this.  

[Primary disk config module](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/zfs/disks/nixos.nix)  
[Syncoid module](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/zfs/syncoid/nixos.nix)  
[Sanoid module](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/zfs/sanoid/nixos.nix)  
[Impermanence module](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/impermanence/nixos.nix)  
Tailscale modules [1](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/tailscale/default.nix) and [2](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/hosts/tailscale/nixos.nix) (1 is shared with darwin hosts, 2 is only for nixos)  
[Nixos-Anywhere Script](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/Utilities/nixos-anywhere/remote-install-encrypt.sh)  
[initrd-ssh unlock script](https://github.com/yomaq/nix-config/blob/5a135a69553d7dfeae412f7eb291a5d067bfb2b4/modules/scripts/initrdunlock.nix)  

Tools and services I use to get all this working:

[Nixos](https://nixos.org/)  
[Nixos Disko module](https://github.com/nix-community/disko)  
[Nixos Anywhere - pairs with disko](https://github.com/nix-community/nixos-anywhere)  
[Nixos Impermanence module](https://github.com/nix-community/impermanence)  

[Tailscale](https://tailscale.com/kb/1017/install)  
[1Password](https://developer.1password.com/)  
[Syncoid and Sanoid](https://github.com/jimsalterjrs/sanoid/)

## NixOS

All of my computers for this purpose are currently running NixOS. My backup servers do have support backing up non-nixos machines, but all of the automation and *convenience* that I am after is lost without NixOS.

NixOS allows you to declaratively and determinately configure machines in a way that no other general OS is able to.
I am using a single NixOS flake to configure all of my systems, and it holds all of the code to configure all of these machines.  

## Disko - declarative partitioning of disks

Disko fills in an empty spot in nixos to allow you to describe and configure your disk partitioning / formatting as code. Which to meet my goal of easily setting new devices up, is rather required, especially if I want to use any non standard disk configuration like zfs.

Collectively my disk configuration currently comes together in my primary config module [linked here](#sources). With config for disko, initrd-ssh, systemd boot, zfs, etc its the longest module in my flake currently. Lets take it apart a bit.

Import disko into the flake

```nix
{
  inputs = {
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  ...
}
```
And import into the host configuration (in my case a shared module which is then imported by every host)
```nix
{ config, lib, inputs, ... }:

{
  imports =[
    inputs.disko.nixosModules.disko
  ];

  ...
}
```


Disko allows you to declaratively configure your disks at install and the mounting of disks after install, meaning the standard mounting configuration in your hardware.nix file is not needed.  
It will only make changes when you first install your system, or re-run disko (which will wipe your disks) However you can make changes to the disko config AND manually make the changes on your disk, then disko will ensure they are mounted as directed in the config.  

Here is an example disko config to setup a basic zfs pool and dataset along with a boot partition.
```nix
{
  disko.devices = {
    # disks config
    disk = {
      x = {
        type = "disk";
        device = "/dev/sdx"; # Needs to be named your specific disk's name
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "64M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };
    # zfs zpool config
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";
        };
        mountpoint = "/";
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^zroot@blank$' || zfs snapshot zroot@blank"; # create a blank snapshot on creation

        # datasets config
        datasets = {
          zfs_fs = {
            type = "zfs_fs";
            mountpoint = "/zfs_fs";
            options."com.sun:auto-snapshot" = "true";
          };
        };
      };
    };
  };
}
```

To reach my goals I want to have some standardization for disk formatting across all devices in my flake. I specifically do NOT want to make a full disko config for each and every device.  
To fit this I created a single shared module that builds all of the disko config for every host, and created some options to allow each host to alter a few specific variables to fit its needs.   
I am running zfs on *all* of my nixos devices currently, over the past year everything has worked really well.
If in the future I have reason to not use zfs on a device I can just add new options to configure disko to setup the disks as needed and just enable those options instead in the device specific config (example below).

Here is the nixos module I use to configure zfs on root:
```nix
{ options, config, lib, pkgs, inputs, ... }:
let
  cfg = config.yomaq.disks;
in
{
  options.yomaq.disks = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom disk configuration
      '';
    };
    zfs = {
      enable = lib.mkOption {
      # This is used later on
        type = lib.types.bool;
        default = false;
      };
      hostID = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      root = {
        encrypt = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        disk1 = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            device name
          '';
        };
        disk2 = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            device name
          '';
        };
        reservation = lib.mkOption {
          type = lib.types.str;
          default = "20GiB";
          description = ''
            zfs reservation
          '';
        };
        mirror = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            mirror the zfs pool
          '';
        };
      };
    };
  };
  config = mkIf (cfg.zfs.root.disk1 != "") {
    disko.devices = {
      one = lib.mkIf {
        type = "disk";
        device = "/dev/${cfg.zfs.root.disk1}";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              label = "EFI";
              name = "ESP";
              size = "2048M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };
            luks = lib.mkIf cfg.zfs.root.encrypt {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted1";
                settings.allowDiscards = true;
                passwordFile = "/tmp/secret.key";
                content = {
                  type = "zfs";
                  pool = "zroot";
                };
              };
            };
            notluks = lib.mkIf (!cfg.zfs.root.encrypt) {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
      two = lib.mkIf (cfg.zfs.root.disk2 != "") {
        type = "disk";
        device = "/dev/${cfg.zfs.root.disk2}";
        content = {
          type = "gpt";
          partitions = {
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted2";
                settings.allowDiscards = true;
                passwordFile = "/tmp/secret.key";
                content = {
                  type = "zfs";
                  pool = "zroot";
                };
              };
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        mode = mkIf cfg.zfs.root.mirror "mirror";
        rootFsOptions = {
          canmount = "off";
          checksum = "edonr";
          compression = "zstd";
          dnodesize = "auto";
          mountpoint = "none";
          normalization = "formD";
          relatime = "on";
          "com.sun:auto-snapshot" = "false";
        };
        options = {
          ashift = "12";
          autotrim = "on";
        };
        datasets = {
          # zfs uses cow free space to delete files when the disk is completely filled
          reserved = {
            options = {
              canmount = "off";
              mountpoint = "none";
              reservation = "${cfg.zfs.root.reservation}";
            };
            type = "zfs_fs";
          };
          # nixos-anywhere currently has issues with impermanence so agenix keys are lost during the install process.
          # as such we give /etc/ssh its own zfs dataset rather than using impermanence to save the keys when we wipe the root directory on boot
          # not needed if you don't use agenix or don't use nixos-anywhere to install
          etcssh = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/etc/ssh";
            options."com.sun:auto-snapshot" = "false";
            postCreateHook = "zfs snapshot zroot/etcssh@empty";
          };
          # dataset where files that don't need to be backed-up but should persist between boots are stored
          # the Impermanence module is what ensures files are correctly stored here
          persist = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/persist";
            options."com.sun:auto-snapshot" = "false";
            postCreateHook = "zfs snapshot zroot/persist@empty";
          };
          # dataset where all files that should both persist and need to be backedup are stored
          # the Impermanence module is what ensures files are correctly stored here
          persistSave = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/persist/save";
            options."com.sun:auto-snapshot" = "false";
            postCreateHook = "zfs snapshot zroot/persistSave@empty";
          };
          # Nix store etc. Needs to persist, but doesn't need backed up
          nix = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/nix";
            options = {
              atime = "off";
              canmount = "on";
              "com.sun:auto-snapshot" = "false";
            };
            postCreateHook = "zfs snapshot zroot/nix@empty";
          };
          # Where everything else lives, and is wiped on reboot by restoring a blank zfs snapshot.
          root = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            options."com.sun:auto-snapshot" = "false";
            mountpoint = "/";
            postCreateHook = ''
                zfs snapshot zroot/root@empty
            '';
          };
        };
      };
    };
  };
}
```


By importing that module into a host, I can configure efficient, easily readable device specific configuration. Simply need to enable the correct modules, and provide the disk device name, and a zfs hostID.

```nix
{ config, lib, pkgs, inputs, ... }:
{
  imports =[
    #import above module here
  ];
  config = {
    yomaq.disks = {
      enable = true;
      zfs = {
        enable = true;
        hostID = "hostsid";
        root = {
          disk1 = "nvme0n1";
        };
      };
    };
    ...
  };
}
```
I also have configuration to setup a zstorage zpool with a couple of datasets in order to handle additional hdd storage devices for backups on my backup server or other such bulk/secondary storage device needs. The configuration is quite similar to the root config. You can see full details for it in the primary module [linked here](#sources).


You will also need to configure nixos to use ZFS properly, I import this into all my nixosConfigurations:
```nix
{ config, lib, pkgs, inputs, ... }:
{
  config = mkIf cfg.zfs.enable {
    networking.hostId = cfg.zfs.hostID;
    environment.systemPackages = [pkgs.zfs-prune-snapshots];
    boot = {
      # Newest kernels might not be supported by ZFS
      kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
      kernelParams = [
        "nohibernate"
        "zfs.zfs_arc_max=17179869184"
      ];
      supportedFilesystems = [ "vfat" "zfs" ];
      zfs = {
        devNodes = "/dev/disk/by-id/";
        forceImportAll = true;
        requestEncryptionCredentials = true;
      };
    };
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };
  };
}
```


## Impermanence - persisting important files, burning the rest

[Erase your darlings](https://grahamc.com/blog/erase-your-darlings/) has become pretty popular when talking about impermanence - where your root directory gets wiped every reboot. Having a clean system where you can have confidence that everything on your disk is what you want and *only* what you want is amazing. But in context with my goals, this practically forces you to place all of the files you care about into a single location, which makes small efficient backups a breeze, so long as you don't go crazy with what files you persist.  

You don't need to use the [impermanence module](https://github.com/nix-community/impermanence) to create this effect, you can configure all of the symlinks yourself, such as described in Erase Your Darlings. However the Impermanence module makes this easy and convenient. So I have chosen to use it.



First import into the flake.nix
```nix
{
  inputs = {
    impermanence.url = "github:nix-community/impermanence";
  };

  ...
}
```
Then I make a module which I import into every host configuration.
The persistent datasets were configured above in the root disko config, I use those in my impermanence config, while allowing devices to alter these directories if needed.
```nix
{ config, lib, pkgs, inputs, ... }:
{
  imports = [inputs.impermanence.nixosModules.impermanence];

  options.yomaq.impermanence = {
    # This allows me to set the persistent locations once and refer to them everywhere.
    backup = lib.mkOption {
      type = lib.types.str;
      default = "/persist/save";
      description = "The persistent directory to backup";
    };
    dontBackup = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "The persistent directory to not backup";
    };
  };
  config = {
    # we'll come back to this when we look at the data restore process
    yomaq.impermanence.backup = lib.mkIf config.yomaq.disks.amReinstalling "/tmp";
  };
}
```
This configures a few variables so that I can refer to the impermanence locations in my other modules.  
For example, to persist important locations in a user directory:
```nix
{ config, lib, pkgs, modulesPath, inputs, ... }:
let
  inherit (config.yomaq.impermanence) dontBackup;
  inherit (config.yomaq.impermanence) backup;
in
{
  environment.persistence."${backup}" = {
    users.yomaq = {
      directories = [
        "nix"
        "documents"
        ".var"
        ".config"
        ".local"
      ];
    };
  };
}
```
By using `${backup}` or `${dontBackup}` I can store the folders in the correct dataset.
For any program or service that I need to retain data for, I have to configure its locations in impermanence otherwise the files with be gone on reboot. While it can be a pain to configure for each location initially, by forcing the files to either be explicitly stored or else destroyed we can make sure all important to files to backup are a single dataset.  
I have some of the basic locations typically needed for the OS configured in my primary config [linked here](#sources).

Back in my disko configuration I have this additional option:

```nix
{ config, lib, pkgs, inputs, ... }:

{
  options = {
    yomaq.disks.zfs.root.impermanenceRoot = mkOption {
      type = types.bool;
      default = false;
      description = ''
        wipe the root directory on boot
      '';
    };
  };
  config = mkIf (cfg.zfs.root.enable && cfg.zfs.root.impermanenceRoot) {
    boot.initrd.postDeviceCommands =
      #wipe / and /var on boot
      lib.mkAfter ''
        zfs rollback -r zroot/root@empty
    '';
  };
}
```
This just runs a command to roll the root directory dataset back to the automatically created empty snapshot every time the computer reboots.
It also provides a toggle so I can disable this behavior if I need to for troubleshooting.

## Syncoid and Sanoid - ZFS snapshot management

Nixos comes with modules for [Syncoid and Sanoid](https://github.com/jimsalterjrs/sanoid) which are some tools to make managing zfs snapshots easily.

Sanoid is used to create and destroy zfs snapshots. It is pretty simple to configure. You can adjust retention durations for the snapshots easily, and pick which datasets you want to snapshot.
```nix
{ options, config, lib, pkgs, inputs, ... }:
let
  cfg = config.yomaq.sanoid;
in
{
  options.yomaq.sanoid = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        enable custom sanoid zfs-snapshot module
      '';
    }; 
  };

  config = lib.mkIf cfg.enable {
    services.sanoid = {
      enable = true;
      templates = {
        default = {
          autosnap = true;
          autoprune = true;
          hourly = 8;
          daily = 1;
          monthly = 1;
          yearly = 1;
        };
      };
      datasets = {
        "zroot/persist".useTemplate = [ "default" ];
        "zroot/persistSave".useTemplate = [ "default" ];
      } // lib.optionalAttrs (config.yomaq.disks.zfs.storage.enable && !config.yomaq.disks.amReinstalling) {
      # This is for the additional zstorage pool I configure in my flake
      # we'll come back to the "amReinstalling" option later on
        "zstorage/storage".useTemplate = [ "default" ];
        "zstorage/persistSave".useTemplate = [ "default" ];
      };
    };
  };
}
```

Syncoid simply transfers datasets from one location to another.  
Here I setup services for transferring the persistSave dataset created above onto the zstorage pool I create in my [primary config](#sources) on a designated backup server. Multiple hosts can be configured to be backup servers without conflict.

I wanted to reduce the amount of manual configuration needed for these backups, so I have the module check the flake for all nixosConfigurations, and generate backup services for each host. I then allow the backup server to exclude any of the devices explicitly, as well as enter additional hostnames to run the backup service for non-nixos machines. Any non-nixos machines I want to backup I'll have to ensure the dataset, the syncoid user, and correct permissions are configured on the non-nixos host.  
Ideally the module would reach into the nixosConfigurations and only create backup tasks for those which have `yomaq.syncoid.enable` set to true. I have done something similar with my homepage module which I plan to make a post about later. The Nixos syncoid module however appears to be setup in such a way that this will create infinite recursions, and I haven't found a way around it yet.

```nix
{ options, config, lib, pkgs, inputs, ... }:
let
  cfg = config.yomaq.syncoid;
  thisHost =  config.networking.hostName;
  allNixosHosts = lib.attrNames inputs.self.nixosConfigurations;
  nixosHosts = lib.lists.subtractLists (cfg.exclude ++ [thisHost]) (allNixosHosts ++ cfg.additionalClients);
in
{
  options.yomaq.syncoid = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable zfs syncoid module
      '';
    };
    isBackupServer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        will run syncoid and backup other nixos hosts
      '';
    };
    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        exclude hosts from backup
      '';
    };
    additionalClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        clients to backup not in the flake
      '';
    };
    datasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["zroot/persistSave"];
      description = ''
        list of datasets syncoid has access to on client
      '';
    };
  };
  config = lib.mkMerge [
    (lib.mkIf config.yomaq.syncoid.enable {
      services.syncoid.enable = true;
      # I need to create the login shell as I am not using the default method of enabling ssh for the user (using tailscale ssh auth instead)
      users.users.syncoid.shell = pkgs.bash;
      # give syncoid user access to send and hold snapshots
      systemd.services = (lib.mkMerge (map (dataset: {
          "syncoid-zfs-allow-${(lib.replaceStrings ["/"] ["-"] "${dataset}")}" = {
            serviceConfig.ExecStart = "${lib.getExe pkgs.zfs} allow -u syncoid bookmark,snapshot,send,hold ${dataset}";
            wantedBy = [ "multi-user.target" ];
          };
        })cfg.datasets));
    })
    (lib.mkIf config.yomaq.syncoid.isBackupServer {
      services.syncoid = {
        enable = true;
        interval = "daily";
        commonArgs = ["--no-sync-snap"];
        commands."${thisHost}Save" = {
          source = "zroot/persistSave";
          target = "zstorage/backups/${thisHost}";
          recvOptions = "c";
        };
      };
      services.sanoid = {
        datasets."zstorage/backups/${thisHost}" = {
            autosnap = false;
            autoprune = true;
            hourly = 0;
            daily = 14;
            monthly = 6;
            yearly = 1;
        };
      };
    })    
    {services.syncoid = lib.mkIf config.yomaq.syncoid.isBackupServer (lib.mkMerge (map ( hostName: {
        commands = {
          "${hostName}Save" = {
          source = "syncoid@${hostName}:zroot/persistSave";
          target = "zstorage/backups/${hostName}";
          recvOptions = "c";
          };
        };
      })nixosHosts));
      services.sanoid = lib.mkIf config.yomaq.syncoid.isBackupServer (lib.mkMerge (map ( hostName: {
        datasets."zstorage/backups/${hostName}" = {
            autosnap = false;
            autoprune = true;
            hourly = 0;
            daily = 14;
            monthly = 6;
            yearly = 1;
        };
      })nixosHosts));
    }
  ];
}
```

With this module imported to each nixosConfiguration, set `config.yomaq.syncoid.enable` for each client. Enable backup servers with just `config.yomaq.syncoid.isBackupServer`.


## Tailscale for Syncoid

I use Tailscale to provide the ssh connections and authentication for the backup service.
Just need Tailscale installed and running on all of your devices, it should be pretty basic. You can check my Tailscale module [linked here](#sources) for an example.

In my Tailscale ACL I have to configure the access and SSH permissions.
```
"tagOwners": {
  "tag:syncoidServer":   [],
  "tag:syncoidClient":   [],
},
"acls": [
  // allow syncoid ssh
  {
    "action": "accept",
    "src":    ["tag:syncoidServer"],
    "dst":    ["tag:syncoidClient:22"],
  },
],
"ssh": [
  // allow syncoid server to ssh into nixos hosts
  {
    "action": "accept",
    "src":    ["tag:syncoidServer"],
    "dst":    ["tag:syncoidClient"],
    "users":  ["syncoid"],
  },
]
```
Then I just tag all my devices as syncoidServer or syncoidClient in Tailscale. 
This grants all syncoidServer tagged devices to SSH into all syncoidClient tagged devices with the `syncoid` account.
With Tailscale SSH I don't need to have any ports exposed, and I can have both the client and server computers be anywhere on any network and have the backup service run securely.


## Syncoid - Restoring from backups

Now that I have a backup server saving datasets for our hosts lets look at restoring a dataset to a host, or moving it to a new host.

First we add an other option to our disko config:

```nix
{ options, config, lib, pkgs, inputs, ... }:
{
  options.yomaq.disks = {
    amReinstalling = mkOption {
      type = types.bool;
      default = false;
      description = ''
        am I reinstalling and want to keep /persist/save unused so I can restore data
      '';
    };
  }:
}
```
This refers back to the Impermanence config from above which sets `yomaq.impermanence.backup = mkIf config.yomaq.disks.amReinstalling "/tmp";`   
When reinstalling a system set `config.yomaq.disks.amReinstalling = true`

Now we can delete the existing `persistSave` dataset on the re-installed client and from our admin machine run a command like:
```
syncoid admin@backupserver:zstorage/backups/client admin@client:zpool/persistSave
```

Then remove the `amReinstalling` line from the config and do a nixos-rebuild and the data restore should be complete.  
The syncoid account on the server only has access to the datasets when the backup service is running, and on the client computers the syncoid account only gets access to send the dataset after it already exists, so you need to use an admin account to run the restore commands.

The `config.yomaq.disks.amReinstalling` option is also something I use elsewhere like for the zstorage zpool, where I specifically do NOT want disko to overwrite the storage disks when I am just trying to re-install the OS on the root OS disks. See the primary config [linked here](#sources)
This allows me to easily re-install Nixos if something breaks without needing to worry about losing the data in my backup disks.

## Nixos-anywhere - Convenient installation for nixos

Nixos-anywhere pairs right alongside with disko. It enables you to ssh into an existing linux machine or pre-install environment, and with a single command it will install your nixos host configuration onto the machine. (encryption complicates this a little)

First boot into a nixos installer (you can make your own nixos iso that automatically connects to your Tailnet so you can access it regardless of what network you may be trying to install to. I may make a post on this later.)



Ensure the  nixos host configuration includes an accurate disko config, then run a command like this to install nixos
```
nix run github:nix-community/nixos-anywhere -- --flake <path to configuration>#<configuration name> root@<ip address>
```


## Luks encryption - Initrd-ssh and Nixos-anywhere

In the above disko module I made, encryption with luks is an option (required for the two disk configuration).
To install the encrypted system I use a script to run nixos-anywhere and pass in the encryption password needed to disko from 1password.
Out of scope, but I also deploy my [agenix](https://github.com/ryantm/agenix) keys this way. If I want to be able to connect to Tailscale on the first boot, I need to already have keys configured with agenix permissions before I install the system.

Obviously don't need to use 1password, but its what I've chosen to use for now.

```bash
#! /run/current-system/sw/bin/bash

ipaddress=$2
hostname=$1

eval $(op signin)

# Create a temporary directory
temp=$(mktemp -d)

# Function to cleanup temporary directory on exit
cleanup() {
  rm -rf "$temp"
}
trap cleanup EXIT

# Create the directory where sshd expects to find the host keys
install -d -m755 "$temp/etc/ssh/"

# Obtain your private key for agenix from the password store and copy it to the temporary directory
# also copy the key for the initrd shh server
op read op:"//nix/$hostname/private key?ssh-format=openssh" > "$temp/etc/ssh/$hostname"


# the initrd keys don't actually seem to work, but initrd secrets does need some kind of key, or it fails.
# initrd ssh won't work, you will need to manually unlock encryption, then generate new keys.
op read op:"//nix/initrd/private key?ssh-format=openssh" > "$temp/etc/ssh/initrd"
# op read op:"//nix/$hostname-initrd/public key" > "$temp/etc/ssh/$hostname-initrd.pub"

# Set the correct permissions so sshd will accept the key
chmod 600 "$temp/etc/ssh/$hostname"
chmod 600 "$temp/etc/ssh/initrd"

# Install NixOS to the host system with our secrets and encryption
nix run github:numtide/nixos-anywhere -- --extra-files "$temp" --build-on-remote \
  --disk-encryption-keys /tmp/secret.key <(op read op://nix/$hostname/encryption) --flake .#$hostname root@$ipaddress
```

Initrd-ssh does complicate this install process a bit further. After the system installs you must unlock it manually first, navigate to `/etc/ssh` delete the initrd key, and regenerate it.
From here you can restore persistSave from a backup server or just do a nixos-rebuild and you are set. Once the system rebuilds initrd-ssh will be available.

I don't want to have to manually ssh into the systems and enter their encryption password every time they reboot. So I built a nix module to deploy a bash script which will dynamically update with all nixos host configurations in my flake, automatically pull the encryption password from 1password, and unlock the disks.

```nix
{ pkgs, inputs, ... }:

let
    hostnamesList = builtins.attrNames inputs.self.nixosConfigurations;
    hostnamesString = builtins.concatStringsSep " " hostnamesList;
in


### I don't use pkgs._1password because I don't use it on macos, and I want the script to work on both

pkgs.writeShellScriptBin "initrd-unlock" ''

if [ "$1" = "--up" ]; then
    hostnames="${hostnamesString}"
    # Iterate over each hostname
    for hostname in $hostnames; do
    # Ping the host
    ping -c 1 "$hostname" > /dev/null 2>&1

    # Check if the ping was successful
    if [ $? -eq 0 ]; then
        echo "$hostname is up"
    else
        echo "Could not reach $hostname"
    fi
    done
else

    # Check if any arguments were provided
    if [ $# -eq 0 ]; then
    # If no arguments were provided, use all nixos hosts
    hostnames="${hostnamesString}"
    else
    # If arguments were provided, use them as the hostnames
    hostnames="$@"
    fi

    # Iterate over each hostname
    for hostname in $hostnames; do
        # Ping the host
        ping -c 1 "$hostname-initrd" > /dev/null 2>&1

        # Check if the ping was successful
        if [ $? -eq 0 ]; then

            #sign into 1password and get the secret
            eval $(op signin)
            password=$(op read op://nix/$hostname/encryption)

            echo -n "$password" | ssh -T root@$hostname-initrd > /dev/null
            echo "unlock sent"

            sleep 8

            ping -c 1 "$hostname-initrd" > /dev/null 2>&1

            # Check if the initrd sshd server has closed
            if [ $? -eq 0 ]; then
                echo "Initrd sshd server still open, unlock may have failed."
            else
                echo "Successfully unlocked"
            fi
        else
            echo "Could not reach $hostname-initrd"
        fi
    done
fi
''
```

You can then install the script on your host like so:
```nix
{ options, config, lib, pkgs, inputs, ... }:
{
  config = cfg.enable {
    environment.systemPackages = with pkgs; [
      (import (inputs.self + /path/to/script/above) {inherit pkgs inputs;})
    ];
 };
}
```

Now, so long as 1password is configured on your system you can run the script `initrd-ssh $HOSTNAME` to unlock the disks.

There are options to unlock luks with the TPM for nixos, but as of now they are not officially supported in Nixos and require significant configuration and setup, all while being a bit fragile.  
As my goal is convenience I have decided to go with initrd-ssh as it is the easiest method to configure, and with the unlock script below is actually easy to unlock devices as well.
A future goal for this is to setup Tailscale SSH for initrd. This will allow me to close the ssh port, as well as unlock devices that are not on my current network. The only pain point with this is the Tailscale OAuth key will need to be renewed every 3 months or else I lose contact, and the key is unencrypted on the device (mostly not an issue so long as your OAuth key permissions are setup properly).


## Initrd-ssh configuration

To setup initrd-ssh itself I use the config below in my primary module.
I use systemd boot, and enable a few settings for the initrd environment. To setup the initrd network I have to specify the ethernet driver that will be in use. I grab this information at the same time I collect the disk device names, and add it to the host configuration before installing NixOS.
Currently I do not have a way to support initrd-ssh over wifi.

```nix
{ options, config, lib, pkgs, inputs, ... }:
let
  authorizedkeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDF1TFwXbqdC1UyG75q3HO1n7/L3yxpeRLIq2kQ9DalI" 
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHYSJ9ywFRJ747tkhvYWFkx/Y9SkLqv3rb7T1UuXVBWo"
  ];
  cfg = config.yomaq.disks;
in
{
  options.yomaq.disks = {
    systemd-boot = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
     initrd-ssh = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      ethernetDrivers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          ethernet drivers to load: (run "lspci -v | grep -iA8 'network\|ethernet'")
        '';
      };
     };
  };
  config = lib.mkMerge [ 
    (lib.mkIf (cfg.enable && cfg.systemd-boot) {
      # setup systemd-boot
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
    })
    (lib.mkIf (cfg.enable && cfg.initrd-ssh.enable) {
      # setup initrd ssh to unlock the encripted drive
      boot.initrd.network.enable = true;
      boot.initrd.availableKernelModules = cfg.initrd-ssh.ethernetDrivers;
      boot.kernelParams = [ "ip=::::${hostName}-initrd::dhcp" ];
      boot.initrd.network.ssh = {
        enable = true;
        port = 22;
        shell = "/bin/cryptsetup-askpass";
        authorizedKeys = authorizedkeys;
        hostKeys = [ "/etc/ssh/initrd" ];
      };
      boot.initrd.secrets = {
        "/etc/ssh/initrd" = "/etc/ssh/initrd";
      };
    })
  ];
}

```

This module is then imported into the host, and the device specific config is setup like this:

```nix
{ config, lib, pkgs, inputs, modulesPath, ... }:
{
  config.yomaq.disks = {
    enable = true;
    systemd-boot = true;
    initrd-ssh = {
      enable = true;
      ethernetDrivers = ["r8169"];
    };
  };
}
```

## Conclusion

I worked most of this out over several months in 2023 and have been using it since. Gradually I am making edits to everything and you can check for the current version on my [flake](https://github.com/yomaq/nix-config/tree/main).
Overall I feel like I have achieved my goals. Things I am still wanting to change are like TMP unlocking for some devices, Tailscale initrd-ssh, maybe an ssh-less backup process. The install process for non-encrypted systems is about as smooth as I think it can get, but encrypted systems require a bit more manual setup than I like and I'm hoping to smooth that process out eventually.