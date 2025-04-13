---
layout: post
title: Nvidia on Nixos WSL - Ollama up 24/7 on your gaming PC
categories:
- Homelab
- Nixos
tags:
- nixos
- wsl
- tailscale
date: 2025-03-31 23:22 -0500
---
### Convenient LLMs at Home

I've been wanting to experiment with LLMs in my homelab, but didn't want the overhead of a dedicated GPU machine or the slowness of CPU processing. I also wanted everything to be convenient long-term: updates needed to be automated, and if the OS dies rebuilding needed to be quick and easy, etc.

Running NixOS with WSL on my gaming PC seemed like the perfect solution, but I kept running into several challenges:

* Concerns of my vram getting locked to LLMs
* WSL would shut down automatically; Microsoft doesn't support WSL running if you aren't actively using it.
* NixOS on WSL didn't support Nvidia out of the box.
* I refused to manage a separate Ubuntu box that would need reconfiguring from scratch.

After hacking away at it for a number of weeks, I've now solved the blocks:

* Ollama (by default) unloads models if they haven't been used in the past 5 minutes.
* WSL automatically starts up, and **stays** running.
* Configured Nvidia Container Toolkit for NixOS on WSL.
* Ollama container configured for NixOS.
* NixOS handles the configuration for the whole system so rebuilding from scratch is easy.
* My NixOS flake is already configured for automatic updates that my WSL system can just inherit.


While there is some generically useful information here, this is heavily NixOS focused. Additionally I **heavily** rely on Tailscale to make my own networking convenient, so there are some optional Tailscale steps included as well.

---
### Live configuration that I actively use at home:
Just here for reference
* [Whole Nixos Flake](https://github.com/yomaq/nix-config)
* [Nvidia Module](https://github.com/yomaq/nix-config/blob/main/modules/hosts/nvidia/nixos.nix)
* [Ollama Container](https://github.com/yomaq/nix-config/blob/main/modules/containers/ollama.nix)
* [Open-WebUI](https://github.com/yomaq/nix-config/blob/main/modules/containers/ollama-webui.nix)
* [Tailscale sidecar Container](https://github.com/yomaq/nix-config/blob/main/modules/containers/tailscale-submodule.nix)
* [Tailscale ACL](https://github.com/yomaq/Tailscale-ACL)

---
### Force WSL to stay running

To start with the biggest wall with an OS agnostic fix, I was able to find [this github post](https://github.com/microsoft/WSL/issues/10138#issuecomment-1593856698). Assuming you are running Ubuntu on WSL you can run 
```
wsl --exec dbus-launch true
```
and this will launch wsl and keep it running. You can setup a basic task in windows Task Scheduler to automatically run this command on `at startup` and set it to run with the user logged out.

For NixOS on WSL I found this didn't quite work, the `--exec` option seeming to have issues. So I set it up like this instead:
```
wsl.exe dbus-launch true
```
I believe for NixOS this means that a shell is left running in the background which is less ideal than using `--exec` for Ubuntu, but I will take what I can get.

---

### Installing NixOS onto WSL

Most of my demands for long term convenience are met by NixOS. With the entire system (nvidia, networking, containers, etc) being configured through your NixOS configuration it makes re-deploying everything a breeze. Additionally my [NixOS Flake](https://github.com/yomaq/nix-config) is already setup for automatic weekly updates through a github action, and all my NixOS hosts are configured to automatically pull and completely rebuild to those updates. My NixOS on WSL will just be able to inherit these benefits.

Alternatively there are [other ways](https://wiki.nixos.org/wiki/Automatic_system_upgrades) to automate updates for a one off NixOS machine for your lone WSL setup if you would like.

To get started with the installation follow the steps from the [Nixos-WSL github](https://github.com/nix-community/NixOS-WSL?tab=readme-ov-file):

1. Enable WSL if you haven't done already:
   ```powershell
    wsl --install --no-distribution
    ```

2. Download `nixos.wsl` from [the latest release](https://github.com/nix-community/NixOS-WSL/releases/latest).

3. Double-click the file you just downloaded (requires WSL >= 2.4.4)

4. You can now run NixOS:
    ```powershell
    wsl -d NixOS
    ```

Then set it as default

```
wsl --setdefault NixOS
```
---

### Basic NixOS configuration

To configure NixOS enter WSL and navigate to `/etc/nixos/`. You'll find a configuration.nix file which will contain the configuration of the entire system, it is very bare bones, we'll add a few basics to make things easier. You'll need to use Nano to edit the file until the first rebuild is complete. (I am using Tailscale for networking I recommend it but its not required.)

```
environment.systemPackages = [
    pkgs.vim
    pkgs.git
    pkgs.tailscale
    pkgs.docker
];
services.tailscale.enable = true;
wsl.useWindowsDriver = true;
nixpkgs.config.allowUnfree = true;
```
Now run
```
sudo nix-channel --update
```
and
```
sudo nixos-rebuild switch
```
Login to Tailscale if you are using it, just follow the link created.
```
sudo tailscale up
```

---

### Configuring NixOS for the Nvidia Container Toolkit

Currently [Nixos on WSL](https://github.com/nix-community/NixOS-WSL?tab=readme-ov-file) doesn't have the same support for nvidia and the nvidia container toolkit that standard NixOS has, so I had to make some adjustments to make it work.

With these fixes, the nvidia container toolkit is working, and you can interact with basic nvidia commands like you'd expect (so far as I've tested, things like `nvidia-smi`) However builtin NixOS modules that rely on Nvidia such as Nixos' `services.ollama` don't work. Likely each of these services would need their own patches to connect to Cuda properly, and I am not attempting to work on those since just using container gpu workloads is fine for me.

That said, here is the configuration to get it working:

```nixos
services.xserver.videoDrivers = ["nvidia"];
hardware.nvidia.open = true;

environment.sessionVariables = {
    CUDA_PATH = "${pkgs.cudatoolkit}";
    EXTRA_LDFLAGS = "-L/lib -L${pkgs.linuxPackages.nvidia_x11}/lib";
    EXTRA_CCFLAGS = "-I/usr/include";
    LD_LIBRARY_PATH = [
        "/usr/lib/wsl/lib"
        "${pkgs.linuxPackages.nvidia_x11}/lib"
        "${pkgs.ncurses5}/lib"
];
    MESA_D3D12_DEFAULT_ADAPTER_NAME = "Nvidia";
};

hardware.nvidia-container-toolkit = {
    enable = true;
    mount-nvidia-executables = false;
};

systemd.services = {
    nvidia-cdi-generator = {
        description = "Generate nvidia cdi";
        wantedBy = [ "docker.service" ];
        serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nvidia-docker}/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml --nvidia-ctk-path=${pkgs.nvidia-container-toolkit}/bin/nvidia-ctk";
        };
    };
};

virtualisation.docker = {
    daemon.settings.features.cdi = true;
    daemon.settings.cdi-spec-dirs = ["/etc/cdi"];
};
```

Do anther `nixos-rebuild switch` and restart WSL.  
Now you should be able to run `nvidia-smi` from the root user, and see your gpu.
You'll need to run all of your docker containers with `--device=nvidia.com/gpu=all` to connect to the gpus.  
*The default nixos user is still defaulting to the windows provided nvidia-smi. The root user, and the user accounts in my flake listed above dont have this issue, I am actively trying to figure this out, its just a PATH issue. You can also run `/run/current-system/sw/bin/nvidia-smi` with the nixos user.*

*I did not discover these fixes on my own, I pieced this information together from these two github issues*:
* https://github.com/nix-community/NixOS-WSL/issues/454
* https://github.com/nix-community/NixOS-WSL/issues/578

---
### Configure Ollama Docker Container:

I've setup an example ollama container, and an optional Tailscale container to pair with it to make networking easier.
If you want to use the Tailscale container uncomment all the code, put your Tailscale domain name in place, and comment out the `port` for the ollama container, and the `networking.firewall` port.

If you use the Tailscale container, it's already setup with Tailscale Serve to provide the Ollama API over signed https at `https://ollama.${YOUR_TAILSCALE_DOMAIN}.ts.net`. 

```nixos
virtualisation.oci-containers.backend = "docker";
virtualisation = {
  docker = {
    enable = true;
    autoPrune.enable = true;
  };
};

systemd.tmpfiles.rules = [ 
  "d /var/lib/ollama 0755 root root" 
  #"d /var/lib/tailscale-container 0755 root root"
];

networking.firewall.allowedTCPPorts = [ 11434 ]; 

virtualisation.oci-containers.containers = {
  "ollama" = {
    image = "docker.io/ollama/ollama:latest";
    autoStart = true;
    environment = {
      "OLLAMA_NUM_PARALLEL" = "1";
    };
    ports = [ 11434 ];
    volumes = [ "/var/lib/ollama:/root/.ollama" ];
    extraOptions = [
      "--pull=always"
      "--device=nvidia.com/gpu=all"
      "--network=container:ollama-tailscale"
    ];
  };

  #"ollama-tailscale" = {
  #  image = "ghcr.io/tailscale/tailscale:latest";
  #  autoStart = true;
  #  environment = {
  #    "TS_HOSTNAME" = "ollama";
  #    "TS_STATE_DIR" = "/var/lib/tailscale";
  #    "TS_SERVE_CONFIG" = "config/tailscaleCfg.json";
  #  };
  #  volumes = [
  #    "/var/lib/tailscale-container:/var/lib"
  #    "/dev/net/tun:/dev/net/tun"
  #    "${
  #    (pkgs.writeTextFile {
  #      name = "ollamaTScfg";
  #      text = ''
  #        {
  #          "TCP": {
  #            "443": {
  #              "HTTPS": true
  #            }
  #          },
  #          "Web": {
  #            #replace this with YOUR tailscale domain 
  #            "ollama.${YOUR_TAILSCALE_DOMAIN}.ts.net:443": {
  #              "Handlers": {
  #                "/": {
  #                  "Proxy": "http://127.0.0.1:11434"
  #                }
  #              }
  #            }
  #          }
  #        }
  #      '';
  #    })
  #    }:/config/tailscaleCfg.json"
  #  ];
  #  extraOptions = [
  #    "--pull=always"
  #    "--cap-add=net_admin"
  #    "--cap-add=sys_module"
  #    "--device=/dev/net/tun:/dev/net/tun"
  #  ];
  #};
};
```

One more `nixos-rebuild switch` and your ollama container should be started.  

---
### Networking and Testing
If using Tailscale:  
* The Tailscale container needs to be setup first, otherwise both containers will keep failing.
* Exec into the Tailscale container `sudo docker exec -it ollama-tailscale sh`
* `tailscale up`
* Use the link to add it to your Tailnet
* Exec into the ollama container to pull a model `sudo docker exec -it ollama ollama run gemma3` 
* Run a test prompt, verify with `nvidia-smi` on wsl to see that the gpu is in use.
* Test the api from another Tailscale connected device:
  ```
  curl https://ollama.${YOUR_TAILSCALE_DOMAIN}.ts.net/api/generate -d '{
    "model": "gemma3",
    "prompt": "test",
    "stream": false
  }'
  ```

If NOT using Tailscale:
* Exec into the ollama container to pull a model `sudo docker exec -it ollama ollama run gemma3` 
* Run a test prompt, verify with `nvidia-smi` on wsl to see that the gpu is in use.
* Ollama is on port 11434 on WSL, follow a guide like this to [expose it to your network through Windows](https://github.com/ollama/ollama/issues/1431)
  * TLDR Add 
    ```
    "OLLAMA_HOST" = "0.0.0.0:11434";
    "OLLAMA_ORIGINS" = "*";
    ```
    to the nixos configuration's ollama environment.
  * Use `ifconfig` to get your WSL ip address, usually under eth0
  * On Windows, using Powershell with Admin rights create firewall rules:
    ```
    New-NetFireWallRule -DisplayName 'WSL firewall unlock' -Direction Outbound -LocalPort 11434 -Action Allow -Protocol TCP

    New-NetFireWallRule -DisplayName 'WSL firewall unlock' -Direction Inbound -LocalPort 11434 -Action Allow -Protocol TCP
    ```
  * Again on Windows Powershell with admin:
    ```
    netsh interface portproxy add v4tov4 listenport=11434 listenaddress=0.0.0.0 connectport=11434 connectaddress=$WSL-IP-ADDRESS
    ```
    Be sure to replace $WSL-IP-ADDRESS
  * Now using your Windows' LAN IP address you should be able to access ollama: `http://192.168.1.123:11434`
* Test api using your Windows LAN IP address.
  ```
  curl http://WINDOWS-LAN-IP:11434/api/generate -d '{
    "model": "gemma3",
    "prompt": "test",
    "stream": false
  }'
  ```
---

### Done!

Now you can connect your Ollama api anywhere you'd like, such as Open-WebUI etc.
