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
  hermesDomain = "hermes.simon-peleska.at";
  hermesPort = 9119;
  geburtstagDomain = "geburtstag.simon-peleska.at";
  geburtstagPort = 8090;

  # Sylvies Geburtstagsseite — a small Go server; templates, CSS and images are
  # embedded in the binary, so there is no runtime state at all.
  geburtstagPkg = pkgs.buildGoModule {
    pname = "geburtstag";
    version = "1.0.0";
    src = ./geburtstag;
    vendorHash = null; # pure stdlib, no dependencies to vendor
  };
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
    storytellerLanguage = "de";
    storytellerTemperature = "1.5";
    storytellerMaxTokens = "1000";
    openaiModel = "openai/gpt-5.6-sol";
    openaiApiBase = "https://openrouter.ai/api/v1";

    narratorProvider = "openai-compatible";
    narratorVoice = "Algieba";
    narratorModel = "google/gemini-3.1-flash-tts-preview";
    # narratorProvider = "elevenlabs";
    # narratorVoice = "l4QW1L3S9K8vu4mB7I0i";
  };

  # ── Hermes agent ───────────────────────────────────────────────────────────
  # Secrets in /var/lib/hermes/env on the server (OPENROUTER_API_KEY).
  services.hermes-agent = {
    enable = true;
    settings.model = {
      default = "anthropic/claude-sonnet-5";
      base_url = "https://openrouter.ai/api/v1";
    };
    environmentFiles = [ "/var/lib/hermes/env" ];
    addToSystemPackages = true;
  };

  # Serve the web dashboard instead of the module's default `hermes gateway`
  # (the Telegram/Discord bridge). Bound to loopback, so Hermes' own auth gate
  # stays off and nginx's basic auth is the only thing guarding it.
  systemd.services.hermes-agent.serviceConfig.ExecStart = lib.mkForce (
    "${config.services.hermes-agent.package}/bin/hermes dashboard"
    + " --no-open --port ${toString hermesPort}"
  );

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

  # ── Geburtstagsseite ───────────────────────────────────────────────────────
  # Stateless: everything is baked into the binary, the only "state" is a cookie
  # in the visitor's browser. Runs unprivileged behind the nginx reverse proxy.
  systemd.services.geburtstag = {
    description = "Sechs Geschenke — Geburtstagsseite";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    environment.ADDR = "127.0.0.1:${toString geburtstagPort}";

    serviceConfig = {
      ExecStart = "${geburtstagPkg}/bin/geschenke";
      Restart = "on-failure";
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
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

    # Catch-all for requests that don't match any server_name below — i.e. scans
    # aimed at the bare IP or a spoofed Host header. Without this nginx falls
    # back to the first vhost and proxies that junk straight into the apps.
    # 444 closes the connection with no response; on 443 the TLS handshake is
    # refused outright, so no certificate is needed here.
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      extraConfig = "return 444;";
    };

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

    # Create the password file on the server (never committed):
    #   nix-shell -p apacheHttpd --run 'htpasswd -c /etc/nginx/hermes.htpasswd simon'
    #   chown nginx:nginx /etc/nginx/hermes.htpasswd && chmod 640 ...
    virtualHosts.${hermesDomain} = {
      enableACME = true;
      forceSSL = true;
      basicAuthFile = "/etc/nginx/hermes.htpasswd";

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString hermesPort}";
        proxyWebsockets = true; # the dashboard talks JSON-RPC over WebSocket
        extraConfig = ''
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };
    };

    virtualHosts.${geburtstagDomain} = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString geburtstagPort}";
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

  # ── fail2ban ───────────────────────────────────────────────────────────────
  # Bans repeat offenders at the firewall, so a scanner that keeps probing stops
  # costing nginx anything.
  #
  # The workhorse is nginx-scan-flood below: it counts 404s and 444s per IP
  # regardless of what was asked for, so there is no probe-path list to maintain.
  # Measured against a day of real traffic, legitimate visitors produced at most
  # ~5 404s (alongside plenty of 200s) while scanners produced 22–271 with almost
  # no 200s, so 20 in 10 minutes sits well clear of both.
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    # Each repeat ban lasts longer than the last, up to a week.
    bantime-increment = {
      enable = true;
      maxtime = "168h";
    };
    jails = {
      # Any IP racking up 404s or 444s fast, whatever it is probing for. Higher
      # maxretry than the global default because a single scan run trips it many
      # times over, while a real visitor never gets close: 20 in 10 minutes is
      # far above a stray hit on the bare IP but far below any real scan.
      nginx-scan-flood.settings = {
        enabled = true;
        filter = "nginx-scan-flood";
        logpath = "/var/log/nginx/access.log";
        backend = "auto";
        maxretry = 20;
        findtime = 600;
      };
      # Kept alongside the above: it catches the wp-login/phpMyAdmin crowd on the
      # global 5-strike threshold, well before they reach 20 404s.
      nginx-botsearch.settings = {
        enabled = true;
        logpath = "/var/log/nginx/access.log";
        backend = "auto";
      };
      # Malformed requests — usually port/protocol scanners speaking the wrong
      # protocol at an HTTPS port.
      nginx-bad-request.settings = {
        enabled = true;
        logpath = "/var/log/nginx/access.log";
        backend = "auto";
      };
      # Brute force against the basic auth on ${hermesDomain}.
      nginx-http-auth.settings = {
        enabled = true;
        logpath = "/var/log/nginx/error.log";
        backend = "auto";
      };
    };
  };

  # Matches 404s (path not found) and 444s (the catch-all vhost above dropping a
  # request whose Host header matched no site), keyed on the client IP.
  # Deliberately path-agnostic — the jail's rate threshold does the work, so this
  # never needs updating as scanners change what they probe for. The empty [] is
  # how fail2ban filters spell "the timestamp datepattern consumed this".
  environment.etc."fail2ban/filter.d/nginx-scan-flood.conf".text = ''
    [Definition]
    failregex = ^<HOST> - \S+ \[\] "[^"]*" (?:404|444)\s
    ignoreregex =
    datepattern = {^LN-BEG}%%ExY(?P<_sep>[-/.])%%m(?P=_sep)%%d[T ]%%H:%%M:%%S(?:[.,]%%f)?(?:\s*%%z)?
                  ^[^\[]*\[({DATE})
                  {^LN-BEG}
  '';

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

  # ── Nix daemon ────────────────────────────────────────────────────────────
  # Allow admin to push unsigned store paths (needed for remote build via laptop).
  nix.settings.trusted-users = [ "root" "admin" ];

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
