{
  description = "CircleCI + Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          system = "x86_64-linux";
        };

        lib = pkgs.lib;

        users = {
          root = {
            uid = 0;
            shell = "${pkgs.bashInteractive}/bin/bash";
            home = "/root";
            gid = 0;
            groups = [ "root" ];
          };

          circleci = {
            uid = 1001;
            shell = "${pkgs.bashInteractive}/bin/bash";
            home = "/home/circleci";
            gid = 1002;
            groups = [ ];
          };
        };

        groups = {
          root.gid = 0;
          circleci.gid = 1002;
        };

        userToPasswd = k: { uid, shell, home, gid, groups }: "${k}:x:${toString uid}:${toString gid}::${home}:${shell}";
        passwdPath = pkgs.writeTextDir "etc/passwd" (
          lib.concatStringsSep "\n" (lib.attrValues (lib.mapAttrs userToPasswd users))
        );

        userToShadow = k: { ... }: "${k}:!:1::::::";
        shadowPath = pkgs.writeTextDir "etc/shadow" (
          lib.concatStringsSep "\n" (lib.attrValues (lib.mapAttrs userToShadow users))
        );

        # Map groups to members
        # {
        #   group = [ "user1" "user2" ];
        # }
        groupMemberMap = (
          let
            # Create a flat list of user/group mappings
            mappings = (
              builtins.foldl'
                (
                  acc: user:
                    let
                      groups = users.${user}.groups or [ ];
                    in
                    acc ++ map
                      (group: {
                        inherit user group;
                      })
                      groups
                )
                [ ]
                (lib.attrNames users)
            );
          in
          (
            builtins.foldl'
              (
                acc: v: acc // {
                  ${v.group} = acc.${v.group} or [ ] ++ [ v.user ];
                }
              )
              { }
              mappings)
        );
        groupToGroup = k: { gid }:
          let
            members = groupMemberMap.${k} or [ ];
          in
          "${k}:x:${toString gid}:${lib.concatStringsSep "," members}";
        groupPath = pkgs.writeTextDir "etc/group" (
          lib.concatStringsSep "\n" (lib.attrValues (lib.mapAttrs groupToGroup groups))
        );

        nixConf = pkgs.writeTextDir "etc/nix/nix.conf" ''
          sandbox = false
          max-jobs = auto
          cores = 0
          trusted-users = root circleci
          experimental-features = nix-command flakes impure-derivations ca-derivations
        '';
      in
      {
        formatter = pkgs.nixpkgs-fmt;

        packages = {
          nixImage = pkgs.dockerTools.buildImageWithNixDb {
            name = "apibara/nix";

            copyToRoot = pkgs.buildEnv {
              name = "image-root";
              pathsToLink = [ "/bin" "/etc" ];
              paths = with pkgs; [
                # config files
                nixConf
                passwdPath
                shadowPath
                groupPath
                # needed by nix
                bashInteractive
                cacert
                coreutils
                nix
                # needed by circleci
                curl
                git
                openssh
                gnutar
                gzip
                # useful
                cachix
              ];
            };

            runAsRoot = with pkgs; ''
              mkdir -p -m 1777 /tmp

              mkdir -p /usr/bin
              ln -s ${coreutils}/bin/env /usr/bin/env

              mkdir -p /home/circleci
              chown -R circleci:circleci /home/circleci
            '';

            config = {
              Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
              Env = [
                "USER=circleci"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              ];
            };
          };
        };
      }
    );
}
