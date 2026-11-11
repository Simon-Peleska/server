# Daily self-update + health + vulnerability check, analysed by Claude Code.
#
# 03:30 UTC  daily-check.service (root)
#   1. sync /var/lib/dailycheck/repo to origin/main of the GitHub repo
#   2. `nix flake update`, build server-1 here, switch to it
#   3. commit + push flake.lock back to GitHub (deploy key)
#   4. reboot if kernel/initrd changed, otherwise start the report right away
# daily-check-report.service (root, also runs once after that reboot)
#   5. health checks + vulnix scan of the running closure
#   6. Claude Code (as unprivileged `dailycheck`, read-only + web search)
#      triages it into runs/<date>/report.md
#   7. Signal "Note to Self" when anything needs attention, a step failed, or
#      as a weekly heartbeat on Mondays
#
# One-time setup (see README section in the commit / deploy notes):
#   sudo daily-check-signal-link            # scan QR with your phone
#   /var/lib/dailycheck/claude.env          # CLAUDE_CODE_OAUTH_TOKEN=... (root, 0600)
#   /var/lib/dailycheck/deploy-key          # write deploy key for the GitHub repo
#
# Reports: /var/lib/dailycheck/latest/report.md (readable by admin)
{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

let
  stateDir = "/var/lib/dailycheck";
  repoHttps = "https://github.com/Simon-Peleska/server.git";
  repoSsh = "git@github.com:Simon-Peleska/server.git";

  # "domain expected-HTTP-status" — checked against nginx on localhost.
  sites = [
    "git.simon-peleska.at 200"
    "werewolf.simon-peleska.at 200"
    "geburtstag.simon-peleska.at 200"
    "jellyfin.simon-peleska.at 302"
    "mosaic.simon-peleska.at 401"
    "janosch.simon-peleska.at 401"
  ];

  claude = pkgsUnstable.claude-code;

  common = ''
    STATE=${stateDir}
    as_dc() { if [ "$(id -u)" = 0 ]; then runuser -u dailycheck -- "$@"; else "$@"; fi; }
  '';

  notify = pkgs.writeShellApplication {
    name = "daily-check-notify";
    runtimeInputs = with pkgs; [ coreutils util-linux signal-cli ];
    text = ''
      ${common}
      msg="$*"
      if [ -e "$STATE/notify-failed" ]; then
        msg="(previous notification on $(cat "$STATE/notify-failed") could not be delivered)"$'\n'"$msg"
      fi
      if [ ! -s "$STATE/signal-account" ]; then
        echo "daily-check-notify: Signal not linked, message was:" >&2
        echo "$msg" >&2
        date -u +%F > "$STATE/notify-failed"
        exit 1
      fi
      acct=$(cat "$STATE/signal-account")
      sc() { as_dc signal-cli --config "$STATE/signal-cli" -a "$acct" "$@"; }
      # Linked devices must receive regularly or Signal eventually drops them.
      sc receive --timeout 5 >/dev/null 2>&1 || true
      if sc send --note-to-self -m "$msg"; then
        rm -f "$STATE/notify-failed"
      else
        echo "daily-check-notify: Signal send failed" >&2
        date -u +%F > "$STATE/notify-failed"
        exit 1
      fi
    '';
  };

  signalLink = pkgs.writeShellApplication {
    name = "daily-check-signal-link";
    runtimeInputs = with pkgs; [ coreutils util-linux gnugrep signal-cli qrencode notify ];
    text = ''
      ${common}
      [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
      echo "Open Signal on your phone → Settings → Linked devices → Link new device, then scan:"
      as_dc signal-cli --config "$STATE/signal-cli" link -n "server-1 daily-check" |
        while IFS= read -r line; do
          case "$line" in
            sgnl://*) qrencode -t ANSIUTF8 "$line" ;;
            *) echo "$line" ;;
          esac
        done
      acct=$(as_dc signal-cli --config "$STATE/signal-cli" listAccounts | grep -o '+[0-9]\+' | head -n1)
      [ -n "$acct" ] || { echo "linking failed"; exit 1; }
      echo "$acct" > "$STATE/signal-account"
      chown dailycheck:dailycheck "$STATE/signal-account"
      daily-check-notify "✅ server-1 daily-check is linked to Signal."
      echo "Linked as $acct; test message sent."
    '';
  };

  update = pkgs.writeShellApplication {
    name = "daily-check-update";
    runtimeInputs = [
      pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.git pkgs.openssh pkgs.util-linux
      config.nix.package config.systemd.package notify
    ];
    text = ''
      ${common}
      set -E
      RUN="$STATE/runs/$(date -u +%F)"
      mkdir -p "$RUN"
      LOG="$RUN/update.log"
      exec > >(tee -a "$LOG") 2>&1
      step=init
      on_err() {
        rc=$?
        sleep 1
        daily-check-notify "❌ server-1 daily update FAILED (step: $step, exit $rc)
      $(tail -n 20 "$LOG")" || true
        exit "$rc"
      }
      trap on_err ERR
      export GIT_SSH_COMMAND="ssh -i $STATE/deploy-key -o IdentitiesOnly=yes -o UserKnownHostsFile=$STATE/known_hosts -o StrictHostKeyChecking=accept-new"
      : > "$RUN/warnings"

      step="git sync"
      if [ ! -d "$STATE/repo/.git" ]; then git clone ${repoHttps} "$STATE/repo"; fi
      cd "$STATE/repo"
      git fetch origin main
      git reset --hard origin/main
      git clean -fd

      step="flake update"
      nix flake update

      step=build
      old=$(readlink -f /run/current-system)
      new=$(nix build --no-link --print-out-paths .#nixosConfigurations.server-1.config.system.build.toplevel)

      step=switch
      if [ "$new" != "$old" ]; then
        nix-env -p /nix/var/nix/profiles/system --set "$new"
        "$new/bin/switch-to-configuration" switch
      fi
      nix store diff-closures "$old" "$new" > "$RUN/closure-diff.txt" 2>&1 || true

      step="push flake.lock"
      pushed="no change"
      if ! git diff --quiet flake.lock; then
        git -c user.name="server-1 daily-check" -c user.email="daily-check@server-1.invalid" \
          commit -q -m "daily-check: update flake.lock" flake.lock
        if git push ${repoSsh} HEAD:main; then pushed=yes
        else pushed=FAILED; echo "flake.lock push to GitHub failed (deploy key missing, or someone pushed meanwhile)" >> "$RUN/warnings"
        fi
      fi

      step="reboot check"
      reboot=no
      for f in kernel initrd kernel-modules; do
        [ "$(readlink -f "/run/booted-system/$f")" = "$(readlink -f "$new/$f")" ] || reboot=yes
      done
      {
        echo "date: $(date -u -Is)"
        echo "commit: $(git rev-parse --short HEAD)"
        echo "old system: $old"
        echo "new system: $new"
        echo "system changed: $([ "$new" != "$old" ] && echo yes || echo no)"
        echo "flake.lock pushed: $pushed"
        echo "reboot: $reboot"
      } > "$RUN/update-summary.txt"

      chgrp -R dailycheck "$RUN"; chmod -R g+rX "$RUN"
      echo "$RUN" > "$STATE/pending-report"
      if [ "$reboot" = yes ]; then
        echo "kernel changed, rebooting; report runs after boot"
        systemctl reboot
      else
        systemctl start --no-block daily-check-report.service
      fi
    '';
  };

  prompt = pkgs.writeText "daily-check-prompt.md" ''
    You are the daily security/health reviewer for server-1, a NixOS 26.05 box on
    Hetzner (public IP 178.104.5.193). Internet-facing via nginx: gitea
    (git.simon-peleska.at), jellyfin, werewolf (Go game server), geburtstag (Go),
    willy/janosch and mosaic (static, basic auth). sshd is public (keys only).
    Only TCP 22/80/443 are open in the firewall. This job just ran `nix flake
    update`, deployed, possibly rebooted, then collected data.

    Files in the current run directory:
      update-summary.txt  what the update did (old/new system, reboot, push)
      closure-diff.txt    package version changes from the update
      warnings            non-fatal problems in the update (may be empty)
      health.txt          failed units, site HTTP checks, disk, ports, fail2ban, logins
      vulnix.txt          vulnix CVE scan of the running system's runtime closure
    A previous run directory (if any) is given below; read its report.md to
    know what was already reported.

    vulnix matches by package name/version and does NOT know about nixpkgs
    patches, so it is very noisy: ignore name collisions (e.g. Rust/npm crates
    named like C libraries), build-only tools, and CVEs nixpkgs already patches.
    For anything that looks real and serious on an internet-facing component
    (nginx, openssh, openssl, gitea, jellyfin, ffmpeg via jellyfin, kernel
    network stack, glibc, Go stdlib in the Go services, sudo, systemd), verify
    with web search: is it real, does it apply to this config, is a fixed
    version in nixos-26.05 or only nixos-unstable/upstream? This flake already
    takes gitea from nixos-unstable; suggest the same overlay pattern if needed.

    Output format, exactly:
    Line 1: `STATUS: OK`, `STATUS: ATTENTION` or `STATUS: CRITICAL`
      CRITICAL  = a site/service is down, or an exploitable remote vuln on an
                  internet-facing component is live.
      ATTENTION = something the owner should act on (a fix available that isn't
                  deployed, failed unit, warnings, disk > 85 %, unexpected open
                  port, suspicious logins, a TLS cert with < 21 days left).
                  A failed acme-order-renew-* unit alone is NOT a reason for
                  ATTENTION: its timer retries and Let's Encrypt often fails
                  transiently; mention it only if that cert has < 21 days left
                  (see "TLS certificates" in health.txt). Don't use ATTENTION for issues the
                  previous report already raised that the owner can't act on yet;
                  list those under "Known" instead.
      OK        = nothing to do.
    Then a block between lines `<signal>` and `</signal>`: plain text, max ~600
    chars, for a phone notification — what's wrong and the concrete next step.
    Then the full markdown report: Summary, Update, Health, Vulnerabilities
    (real ones first, with reasoning; then one line on how much noise was
    dismissed), Known/ongoing, Recommended actions. Be concise.
  '';

  report = pkgs.writeShellApplication {
    name = "daily-check-report";
    runtimeInputs = [
      pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.curl
      pkgs.iproute2 pkgs.procps pkgs.util-linux pkgs.vulnix pkgs.git pkgs.openssl claude
      config.nix.package config.systemd.package config.networking.firewall.package
      config.services.fail2ban.package notify
    ];
    text = ''
      ${common}
      set -E
      RUN=$(cat "$STATE/pending-report" 2>/dev/null || echo "$STATE/runs/$(date -u +%F)")
      rm -f "$STATE/pending-report"
      mkdir -p "$RUN"
      LOG="$RUN/report.log"
      exec > >(tee -a "$LOG") 2>&1
      step=init
      on_err() {
        rc=$?
        sleep 1
        daily-check-notify "❌ server-1 daily report FAILED (step: $step, exit $rc)
      $(tail -n 20 "$LOG")" || true
        exit "$rc"
      }
      trap on_err ERR
      cd "$RUN"
      touch warnings update-summary.txt closure-diff.txt

      # Give services a moment after a fresh boot.
      up=$(cut -d. -f1 /proc/uptime)
      [ "$up" -gt 180 ] || sleep $((180 - up))

      step=health
      bad=""
      {
        echo "## System"
        echo "kernel: $(uname -r)   uptime: $(uptime)"
        # Only kernel/initrd/modules need a reboot; other differences are applied live by switch.
        kdiff=""
        for f in kernel initrd kernel-modules; do
          [ "$(readlink -f "/run/booted-system/$f")" = "$(readlink -f "/run/current-system/$f")" ] || kdiff+="$f "
        done
        if [ -z "$kdiff" ]; then
          echo "kernel/initrd/modules match the booted system: no reboot needed"
        else
          echo "REBOOT PENDING: $kdiff differ from the booted system"
        fi
        echo; echo "## Failed units"
        failed=$(systemctl --failed --no-legend --plain)
        echo "''${failed:-none}"
        echo; echo "## Sites (via nginx on 127.0.0.1)"
        while read -r d want; do
          got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$d:443:127.0.0.1" "https://$d/" || true)
          echo "$d expected $want got $got"
        done <<'EOF'
      ${lib.concatStringsSep "\n" sites}
      EOF
        # Read straight from disk: no TLS connections, so nothing for fail2ban
        # (nginx logs a handshake-only connection as a 400 bad request).
        echo; echo "## TLS certificates (days left, from /var/lib/acme)"
        while read -r d _; do
          f=/var/lib/acme/$d/cert.pem
          if end=$(openssl x509 -noout -enddate -in "$f" 2>/dev/null | cut -d= -f2); then
            echo "$d cert_days_left $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 )) (expires $end)"
          else
            echo "$d cert_days_left -1 (no readable cert at $f)"
          fi
        done <<'EOF'
      ${lib.concatStringsSep "\n" sites}
      EOF
        echo; echo "## Disk"; df -h / | tail -n1
        echo; echo "## Memory"; free -h
        echo; echo "## Listening sockets (non-loopback)"
        ss -Htulpn | grep -v -e '127\.0\.0\.' -e '\[::1\]' || true
        echo; echo "## Firewall accepts"; iptables -S nixos-fw | grep -- '-j nixos-fw-accept' || true
        echo; echo "## fail2ban"
        for j in $(fail2ban-client status | sed -n 's/.*Jail list:\s*//p' | tr ',' ' '); do
          echo "$j: $(fail2ban-client status "$j" | grep -E 'Currently banned|Total banned' | awk -F: '{gsub(/ /,"",$2); printf "%s=%s ", $1, $2}')"
        done
        echo; echo "## Successful SSH logins, last 24h"
        journalctl -u sshd --since -24h --no-pager -q | grep -E 'Accepted ' | tail -n 20 || true
      } > health.txt 2>&1
      # A failed ACME renewal is retried by its timer and Let's Encrypt often
      # 400s transiently; only the cert expiry below decides whether it matters.
      ! systemctl --failed --no-legend --plain | grep -qv 'acme-order-renew-' || bad+="failed units; "
      while read -r d _ days _; do
        [ "$days" -ge 21 ] || bad+="TLS cert for $d expires in $days days; "
      done < <(grep ' cert_days_left ' health.txt)
      while read -r d want got; do
        [ "$want" = "$got" ] || bad+="$d returned $got (expected $want); "
      done < <(grep ' expected ' health.txt | awk '{print $1, $3, $5}')
      usep=$(df --output=pcent / | tail -n1 | tr -dc 0-9)
      [ "$usep" -lt 90 ] || bad+="disk $usep% full; "

      step=vulnix
      # vulnix needs the .drv of every package. Systems deployed from the desktop
      # arrive without them, so evaluate the repo (recreates .drv files, no
      # build) and scan each runtime path's deriver that exists on this host.
      if [ -d "$STATE/repo/.git" ]; then
        (cd "$STATE/repo" && nix path-info --derivation .#nixosConfigurations.server-1.config.system.build.toplevel > /dev/null) \
          || echo "warning: could not evaluate repo to recreate .drv files"
      fi
      nix-store -qR /run/current-system | xargs -r nix-store -qd 2>/dev/null \
        | grep -v '^unknown-deriver' | sort -u > drvs.all || true
      : > drvs
      while read -r d; do [ ! -e "$d" ] || echo "$d" >> drvs; done < drvs.all
      [ -s drvs ] || { echo "no derivations found for /run/current-system"; false; }
      mapfile -t drvlist < drvs
      rc=0
      as_dc vulnix --cache-dir "$STATE/.cache/vulnix" -R "''${drvlist[@]}" > vulnix.txt 2>&1 || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 2 ] || { echo "vulnix exit $rc"; tail -n 20 vulnix.txt; false; }
      echo "coverage: scanned $(wc -l < drvs) of $(wc -l < drvs.all) runtime packages ($(($(wc -l < drvs.all) - $(wc -l < drvs))) had no .drv on this host)" >> vulnix.txt
      nvuln=$(grep -cE '^[A-Za-z0-9_.+-]+-[0-9][^ ]*$' vulnix.txt || true)
      chgrp -R dailycheck "$RUN"; chmod -R g+rX "$RUN"

      step=claude
      prev=$(find "$STATE/runs" -mindepth 1 -maxdepth 1 -type d ! -path "$RUN" | sort | tail -n1)
      claude_ok=no
      if [ -s "$STATE/claude.env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$STATE/claude.env"
        set +a
        export DISABLE_AUTOUPDATER=1
        msg="$(cat ${prompt})"$'\n\n'"Current run directory: $RUN"$'\n'"Previous run directory: ''${prev:-none}"
        allowed="Read($RUN/**),Glob($RUN/**),Grep($RUN/**),WebSearch,WebFetch"
        [ -z "$prev" ] || allowed+=",Read($prev/**)"
        if timeout 30m runuser -u dailycheck -- claude -p "$msg" \
             --allowedTools "$allowed" \
             --disallowedTools "Bash,Edit,Write,NotebookEdit" \
             --max-turns 60 > report.md.tmp 2> claude.err \
           && grep -q '^STATUS: ' report.md.tmp; then
          mv report.md.tmp report.md
          claude_ok=yes
        else
          echo "claude failed:"; tail -n 20 claude.err report.md.tmp 2>/dev/null || true
        fi
      else
        echo "no $STATE/claude.env, skipping Claude" > claude.err
      fi

      step=notify
      ln -sfn "$RUN" "$STATE/latest"
      chgrp -R dailycheck "$RUN"; chmod -R g+rX "$RUN"
      find "$STATE/runs" -mindepth 1 -maxdepth 1 -type d -mtime +60 -exec rm -rf {} +

      warn=$(cat warnings)
      if [ "$claude_ok" = yes ]; then
        status=$(head -n1 report.md | sed 's/^STATUS: *//')
        summary=$(sed -n '/^<signal>/,/^<\/signal>/p' report.md | sed '1d;$d')
        text=""
        [ -z "$bad" ] || text+="Health: $bad"$'\n'
        text+="$summary"
        if [ "$status" != OK ] || [ -n "$bad" ]; then
          daily-check-notify "⚠️ server-1: $status"$'\n'"$text"$'\n'"Full report: $STATE/latest/report.md"
        elif [ "$(date -u +%u)" = 1 ]; then
          daily-check-notify "✅ server-1 weekly heartbeat: all OK."$'\n'"$summary"
        fi
      else
        {
          echo "STATUS: UNKNOWN (Claude analysis failed)"
          echo; echo "## Update"; cat update-summary.txt
          echo; echo "## Warnings"; cat warnings
          echo; echo "## Health"; cat health.txt
          echo; echo "## Claude error"; tail -n 30 claude.err
        } > report.md
        daily-check-notify "⚠️ server-1: Claude analysis failed ($(tail -n1 claude.err | cut -c1-200))
      Health: ''${bad:-ok}
      Warnings: ''${warn:-none}
      vulnix flagged $nvuln packages (unreviewed).
      Raw report: $STATE/latest/report.md"
      fi
      echo "report done: $RUN/report.md"
    '';
  };
in
{
  users.groups.dailycheck = { };
  users.users.dailycheck = {
    isSystemUser = true;
    group = "dailycheck";
    home = stateDir;
    createHome = false;
  };
  # So `admin` can read the reports without sudo.
  users.users.admin.extraGroups = [ "dailycheck" ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 dailycheck dailycheck -"
    "d ${stateDir}/runs 0750 dailycheck dailycheck -"
  ];

  environment.systemPackages = [ notify signalLink update report ];

  systemd.services.daily-check = {
    description = "Daily self-update of server-1 (flake update, build, switch)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Don't let the switch this unit performs stop/restart the unit itself.
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe update;
      TimeoutStartSec = "3h";
    };
  };

  systemd.timers.daily-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      RandomizedDelaySec = "20m";
      Persistent = true;
    };
  };

  systemd.services.daily-check-report = {
    description = "Daily health + vulnerability report for server-1 (Claude Code)";
    # Also runs once after the reboot the update triggered (marker file).
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nginx.service" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${stateDir}/pending-report";
    restartIfChanged = false;
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe report;
      TimeoutStartSec = "1h";
    };
  };

  # Builds now happen here every day: keep generations and the store in check.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.grub.configurationLimit = 20;
}
