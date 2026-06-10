{
  config,
  lib,
  pkgs,
  inputs,
  modulesPath,
  ...
}:

let
  domain = "werewolf.simon-peleska.at";
  gitDomain = "git.simon-peleska.at";
  jellyfinDomain = "jellyfin.simon-peleska.at";
  sshPubKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwpQ60GkyiUQzKvQXwx+TEVrJ6Gtyr81OXkEshRm/SW"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHFqwByfThvVa8/np6/Ujrz0d6cb3RztwCbY78d25eRA simon@Framework"
  ];

  # Set this to the disk device shown in rescue mode (lsblk).
  # Typically /dev/sda on HDD/SSD servers, /dev/nvme0n1 on NVMe.
  disk = "/dev/sda";
in

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ── Disk layout (disko) ────────────────────────────────────────────────────
  # nixos-anywhere uses this to partition and format the disk automatically.
  # GPT + 1 MiB BIOS boot partition (required for GRUB on GPT) + ext4 root.
  # https://wiki.nixos.org/wiki/Install_NixOS_on_Hetzner_Cloud
  disko.devices.disk.main = {
    type = "disk";
    device = disk;
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition — GRUB writes stage 1.5 here
          priority = 1; # must be first on disk
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub.enable = true; # device is set automatically by disko

  # ── Werewolf service ───────────────────────────────────────────────────────
  # API keys go in /etc/werewolf/secrets on the server (never committed).
  # Create it manually:
  #   echo "OPENAI_API_KEY=sk-..."   > /etc/werewolf/secrets
  #   echo "NARRATOR_API_KEY=sk-..." >> /etc/werewolf/secrets
  #   chown root:werewolf /etc/werewolf/secrets && chmod 640 /etc/werewolf/secrets
  services.werewolf = {
    enable = true;
    package = inputs.werewolf.packages.x86_64-linux.default;

    environmentFile = "/etc/werewolf/secrets";

    storyteller = true;
    storytellerTemperature = "1.4";
    openaiModel = "openai/gpt-oss-120b";
    openaiApiBase = "https://api.groq.com/openai/v1";

    narratorProvider = "elevenlabs";
    narratorVoice = "c8MZcZcr0JnMAwkwnTIu";
  };

  # ── Gitea ──────────────────────────────────────────────────────────────────
  # Self-hosted git. Listens locally on HTTP_PORT; nginx terminates TLS and
  # reverse-proxies to it (see virtualHosts.${gitDomain} below).
  # DNS for ${gitDomain} must point at this server's IP before ACME can issue
  # a certificate for it.
  services.gitea = {
    enable = true;
    appName = "Simon's Gitea";
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN = gitDomain;
        ROOT_URL = "https://${gitDomain}/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3000;
      };
      service = {
        DISABLE_REGISTRATION = true;
      };
    };
  };

  # ── Jellyfin media server ──────────────────────────────────────────────────
  # Media library, config and metadata live under /var/lib/jellyfin (persisted).
  # Drop media files somewhere like /srv/media and add libraries via the web UI
  # at https://jellyfin.simon-peleska.at on first run.
  services.jellyfin = {
    enable = true;
    openFirewall = false; # only reachable through the nginx reverse proxy
  };

  # ── nginx + HTTPS ──────────────────────────────────────────────────────────
  security.acme = {
    acceptTerms = true;
    defaults.email = ""; # used for expiry notifications
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;

    virtualHosts.${domain} = {
      enableACME = true; # NixOS automatically renews via systemd timer
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://${config.services.werewolf.listenAddr}";
        proxyWebsockets = true; # game uses persistent WebSocket connections
        extraConfig = ''
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };
    };

    virtualHosts.${gitDomain} = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://${config.services.gitea.settings.server.HTTP_ADDR}:${toString config.services.gitea.settings.server.HTTP_PORT}";
      };
    };

    virtualHosts.${jellyfinDomain} = {
      enableACME = true;
      forceSSL = true;

      # Allow large uploads (e.g. when syncing/transcoding); off-by-default in nginx.
      extraConfig = ''
        client_max_body_size 20M;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:8096"; # Jellyfin's default HTTP port
        proxyWebsockets = true; # required for the web client's live updates
        extraConfig = ''
          proxy_buffering off; # better streaming behaviour
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # ── Automatic OS updates ───────────────────────────────────────────────────
  # Pulls the latest commit from this flake's GitHub repo and switches to it.
  # The werewolf version is pinned via flake.lock — run `nix flake update werewolf`
  # in this repo and push to deploy a new game version.
  # system.autoUpgrade = {
  #   enable = true;
  #   flake = "github:simon-peleska/server";
  #   dates = "04:00"; # daily at 4 AM
  #   randomizedDelaySec = "1h"; # spread load if you run multiple servers
  #   allowReboot = true; # reboot automatically after kernel upgrades
  # };

  # ── Machine basics ─────────────────────────────────────────────────────────
  networking.hostName = "server-1";

  # ── Static networking (Hetzner Cloud) ─────────────────────────────────────
  # IPv4 is /32 on Hetzner — the gateway 172.31.1.1 is not in the same subnet,
  # so GatewayOnLink = true is required.
  # https://wiki.nixos.org/wiki/Install_NixOS_on_Hetzner_Cloud
  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.networks."30-wan" = {
    matchConfig.Name = "ens3"; # ens3 on amd64; enp1s0 on arm64 — verify with `ip addr`
    networkConfig.DHCP = "no";
    address = [
      "178.104.5.193/32"
      "2a01:4f8:1c19:1d5a::1/64"
    ];
    routes = [
      {
        Gateway = "172.31.1.1";
        GatewayOnLink = true;
      }
      { Gateway = "fe80::1"; }
    ];
  };

  environment.systemPackages = [ pkgs.neovim ];

  time.timeZone = "UTC";

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "no";
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshPubKeys;
  };

  # Allow `admin` to run sudo without a password (optional — remove if you prefer typed sudo).
  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "26.05";
}
