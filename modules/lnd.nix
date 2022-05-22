{ config, lib, pkgs, ... }:

with lib;
let
  options.services.lnd = {
    enable = mkEnableOption "Lightning Network daemon, a Lightning Network implementation in Go";
    address = mkOption {
      type = types.str;
      default = "localhost";
      description = "Address to listen for peer connections";
    };
    port = mkOption {
      type = types.port;
      default = 9735;
      description = "Port to listen for peer connections";
    };
    rpcAddress = mkOption {
      type = types.str;
      default = "localhost";
      description = "Address to listen for RPC connections.";
    };
    rpcPort = mkOption {
      type = types.port;
      default = 10009;
      description = "Port to listen for gRPC connections.";
    };
    restAddress = mkOption {
      type = types.str;
      default = "localhost";
      description = "Address to listen for REST connections.";
    };
    restPort = mkOption {
      type = types.port;
      default = 8080;
      description = "Port to listen for REST connections.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lnd";
      description = "The data directory for LND.";
    };
    networkDir = mkOption {
      readOnly = true;
      default = "${cfg.dataDir}/chain/bitcoin/${bitcoind.network}";
      description = "The network data directory.";
    };
    useNeutrino = mkEnableOption "Use an Neutrino light node instead of bitcoind";
    tor-socks = mkOption {
      type = types.nullOr types.str;
      default = if cfg.tor.proxy then config.nix-bitcoin.torClientAddressWithPort else null;
      description = "Socks proxy for connecting to Tor nodes";
    };
    macaroons = mkOption {
      default = {};
      type = with types; attrsOf (submodule {
        options = {
          user = mkOption {
            type = types.str;
            description = "User who owns the macaroon.";
          };
          permissions = mkOption {
            type = types.str;
            example = ''
              {"entity":"info","action":"read"},{"entity":"onchain","action":"read"}
            '';
            description = "List of granted macaroon permissions.";
          };
        };
      });
      description = ''
        Extra macaroon definitions.
      '';
    };
    staticChannelBackupScript = mkOption {
      type = with types; nullOr str;
      default = null;
      description = "Script to be invoked whenever channels.backup changes";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        autopilot.active=1
      '';
      description = "Extra lines appended to <filename>lnd.conf</filename>.";
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.lnd;
      defaultText = "config.nix-bitcoin.pkgs.lnd";
      description = "The package providing lnd binaries.";
    };
    cli = mkOption {
      default = pkgs.writeScriptBin "lncli"
        # Switch user because lnd makes datadir contents readable by user only
        ''
          ${runAsUser} ${cfg.user} ${cfg.package}/bin/lncli \
            --rpcserver ${cfg.rpcAddress}:${toString cfg.rpcPort} \
            --tlscertpath '${cfg.certPath}' \
            --macaroonpath '${networkDir}/admin.macaroon' "$@"
        '';
      defaultText = "(See source)";
      description = "Binary to connect with the lnd instance.";
    };
    getPublicAddressCmd = mkOption {
      type = types.str;
      default = "";
      description = ''
        Bash expression which outputs the public service address to announce to peers.
        If left empty, no address is announced.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "lnd";
      description = "The user as which to run LND.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run LND.";
    };
    certPath = mkOption {
      readOnly = true;
      default = "${secretsDir}/lnd-cert";
      description = "LND TLS certificate path.";
    };
    tor = nbLib.tor;
  };

  cfg = config.services.lnd;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  runAsUser = config.nix-bitcoin.runAsUserCmd;
  lndinit = "${config.nix-bitcoin.pkgs.lndinit}/bin/lndinit";

  bitcoind = config.services.bitcoind;

  bitcoindRpcAddress = nbLib.address bitcoind.rpc.address;
  networkDir = cfg.networkDir;
  configFile = pkgs.writeText "lnd.conf" ''
    datadir=${cfg.dataDir}
    logdir=${cfg.dataDir}/logs
    tlscertpath=${cfg.certPath}
    tlskeypath=${secretsDir}/lnd-key

    listen=${toString cfg.address}:${toString cfg.port}
    rpclisten=${cfg.rpcAddress}:${toString cfg.rpcPort}
    restlisten=${cfg.restAddress}:${toString cfg.restPort}

    bitcoin.${bitcoind.network}=1
    bitcoin.active=1

    ${optionalString (cfg.tor.proxy) "tor.active=true"}
    ${optionalString (cfg.tor-socks != null) "tor.socks=${cfg.tor-socks}"}
    ${optionalString (!cfg.useNeutrino) ''
    bitcoin.node=bitcoind
    bitcoind.rpchost=${bitcoindRpcAddress}:${toString bitcoind.rpc.port}
    bitcoind.rpcuser=${bitcoind.rpc.users.public.name}
    bitcoind.zmqpubrawblock=${bitcoind.zmqpubrawblock}
    bitcoind.zmqpubrawtx=${bitcoind.zmqpubrawtx}
    ''}
      ${optionalString cfg.useNeutrino ''
        bitcoin.node=neutrino
        feeurl=https://nodes.lightning.computer/fees/v1/btc-fee-estimates.json
    ''}
    ${cfg.extraConfig}
  '';
in {

  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion =
          !(config.services ? clightning)
          || !config.services.clightning.enable
          || config.services.clightning.port != cfg.port;
        message = ''
          LND and clightning can't both bind to lightning port 9735. Either
          disable LND/clightning or change services.clightning.port or
          services.lnd.port to a port other than 9735.
        '';
      }
    ];

    services.bitcoind = {
      enable = !cfg.useNeutrino;

      # Increase rpc thread count due to reports that lightning implementations fail
      # under high bitcoind rpc load
      rpc.threads = 16;

      zmqpubrawblock = "tcp://${bitcoindRpcAddress}:28332";
      zmqpubrawtx = "tcp://${bitcoindRpcAddress}:28333";
    };

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.lnd = {
      wantedBy = [ "multi-user.target" ];
      requires = if cfg.useNeutrino then [] else [ "bitcoind.service" ];
      after = if cfg.useNeutrino then [] else [ "bitcoind.service" ];
      preStart = ''
        install -m600 ${configFile} '${cfg.dataDir}/lnd.conf'
        {
          echo "bitcoind.rpcpass=$(cat ${secretsDir}/bitcoin-rpcpassword-public)"
          ${optionalString (cfg.getPublicAddressCmd != "") ''
            echo "externalip=$(${cfg.getPublicAddressCmd})"
          ''}
        } >> '${cfg.dataDir}/lnd.conf'

        if [[ ! -f ${networkDir}/wallet.db ]]; then
          seed='${cfg.dataDir}/lnd-seed-mnemonic'

          if [[ ! -f "$seed" ]]; then
            echo "Create lnd seed"
            (umask u=r,go=; ${lndinit} gen-seed > "$seed")
          fi

          echo "Create lnd wallet"
          ${lndinit} -v init-wallet \
            --file.seed="$seed" \
            --file.wallet-password='${secretsDir}/lnd-wallet-password' \
            --init-file.output-wallet-dir='${cfg.networkDir}'
        fi
      '';
      serviceConfig = nbLib.defaultHardening // {
        Type = "notify";
        RuntimeDirectory = "lnd"; # Only used to store custom macaroons
        RuntimeDirectoryMode = "711";
        ExecStart = ''
          ${cfg.package}/bin/lnd \
            --configfile="${cfg.dataDir}/lnd.conf" \
            --wallet-unlock-password-file="${secretsDir}/lnd-wallet-password"
        '';
        User = cfg.user;
        TimeoutSec = "15min";
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
        ExecStartPost = let
          curl = "${pkgs.curl}/bin/curl -fsS --cacert ${cfg.certPath}";
          restUrl = "https://${nbLib.addressWithPort cfg.restAddress cfg.restPort}/v1";
        in
          # Setting macaroon permissions for other users needs root permissions
          nbLib.rootScript "lnd-create-macaroons" ''
            umask ug=r,o=
            ${lib.concatMapStrings (macaroon: ''
              echo "Create custom macaroon ${macaroon}"
              macaroonPath="$RUNTIME_DIRECTORY/${macaroon}.macaroon"
              ${curl} \
                -H "Grpc-Metadata-macaroon: $(${pkgs.xxd}/bin/xxd -ps -u -c 99999 '${networkDir}/admin.macaroon')" \
                -X POST \
                -d '{"permissions":[${cfg.macaroons.${macaroon}.permissions}]}' \
                ${restUrl}/macaroon |\
                ${pkgs.jq}/bin/jq -c '.macaroon' | ${pkgs.xxd}/bin/xxd -p -r > "$macaroonPath"
              chown ${cfg.macaroons.${macaroon}.user}: "$macaroonPath"
            '') (attrNames cfg.macaroons)}
          '';
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };
    
    systemd.paths.lnd-channel-backup = mkIf (cfg.staticChannelBackupScript != null) {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.dataDir + "/chain/bitcoin/${bitcoind.network}/channel.backup";
        Unit = "lnd-channel-backup.service";
      };
    };

    systemd.services.lnd-channel-backup = mkIf (cfg.staticChannelBackupScript != null) {
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
      };
      script = cfg.staticChannelBackupScript;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "bitcoinrpc-public" ];
      home = cfg.dataDir; # lnd creates .lnd dir in HOME
    };
    users.groups.${cfg.group} = {};
    nix-bitcoin.operator = {
      groups = [ cfg.group ];
      allowRunAsUsers = [ cfg.user ];
    };

    nix-bitcoin.secrets = {
      lnd-wallet-password.user = cfg.user;
      lnd-key.user = cfg.user;
      lnd-cert.user = cfg.user;
      lnd-cert.permissions = "444"; # world readable
    };
    # Advantages of manually pre-generating certs:
    # - Reduces dynamic state
    # - Enables deployment of a mesh of server plus client nodes with predefined certs
    nix-bitcoin.generateSecretsCmds.lnd = ''
      makePasswordSecret lnd-wallet-password
      makeCert lnd '${optionalString (cfg.rpcAddress != "localhost") "IP:${cfg.rpcAddress}"}'
    '';
  };
}
