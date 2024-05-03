{
  description = "A simple ruby app demo";

  nixConfig = {
    extra-substituters = "https://nixpkgs-ruby.cachix.org";
    extra-trusted-public-keys = "nixpkgs-ruby.cachix.org-1:vrcdi50fTolOxWCZZkw0jakOnUI1T19oYJ+PRYdK4SM=";
  };

  inputs = {
    nixpkgs.url = "nixpkgs";
    ruby-nix.url = "github:inscapist/ruby-nix";
    # a fork that supports platform dependant gem
    bundix = {
      url = "github:inscapist/bundix/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fu.url = "github:numtide/flake-utils";
    bob-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";
    bob-ruby.inputs.nixpkgs.follows = "nixpkgs";
    nix2container.url = "github:nlewo/nix2container";
  };

  outputs =
    {
      self,
      nixpkgs,
      fu,
      ruby-nix,
      bundix,
      bob-ruby,
      nix2container,
    }:
    with fu.lib;
    eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ bob-ruby.overlays.default ];
        };
        rubyNix = ruby-nix.lib pkgs;

        # TODO generate gemset.nix with bundix
        gemset = if builtins.pathExists ./gemset.nix then import ./gemset.nix else { };

        # If you want to override gem build config, see
        #   https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/ruby-modules/gem-config/default.nix
        gemConfig = { };

        # See available versions here: https://github.com/bobvanderlinden/nixpkgs-ruby/blob/master/ruby/versions.json
        ruby = pkgs."ruby-3.3.0";

        # Running bundix would regenerate `gemset.nix`
        bundixcli = bundix.packages.${system}.default;

        # Use these instead of the original `bundle <mutate>` commands
        bundleLock = pkgs.writeShellScriptBin "bundle-lock" ''
          export BUNDLE_PATH=vendor/bundle
          bundle lock
        '';
        bundleUpdate = pkgs.writeShellScriptBin "bundle-update" ''
          export BUNDLE_PATH=vendor/bundle
          bundle lock --update
        '';

        src = pkgs.fetchFromGitHub {
            owner = "tomgeorge";
            repo = "rails-blog-nix";
            rev = "852747a6a0b8bcd0d8216d16b25be4019f6a453a";
            sha256 = "sha256-kScTyo5ZmSZNO4QGrDxlMqH+kzcoZsX+g/sUgLtqhzU=";
        };

        nix2containerPkgs = nix2container.packages;

      in
      rec {
        rubyEnv = (rubyNix {
            inherit gemset ruby;
            name = "my-rails-app";
            gemConfig = pkgs.defaultGemConfig // gemConfig;
          }).env;
         
        assets = pkgs.stdenv.mkDerivation {
          inherit src;
          name = "precompiled-sources";
          buildInputs = [ rubyEnv ];
          buildPhase = ''
            runHook preBuild
            set -x
            pwd
            export RAILS_LOG_TO_STDOUT=1
            export RAILS_ENV="production"
            bundle exec bootsnap precompile --gemfile
            bundle exec bootsnap precompile app/ lib/
            chmod -R +w tmp
            SECRET_KEY_BASE_DUMMY=1 bundle exec rake assets:precompile
            mkdir -p $out && cp -r ./public/ $out
            runHook postBuild
          '';
        };

        deploy = pkgs.stdenv.mkDerivation { 
          inherit src;
          name = "runtime";
          buildInputs = [ assets ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out && cp -r . $out
            cp -r ${assets} $out/assets
            runHook postInstall
          '';
        };

        othercontainer = nix2containerPkgs.${system}.nix2container.buildImage {
            name = "localhost/rails-blog-via-nix2container";
            tag = "latest";
            config = {
              Cmd = [ "${rubyEnv}/bin/bundle" "exec" "rails" "server" "-b" "0.0.0.0"];
              WorkingDir = "${deploy}";
              Env = [
                "RAILS_LOG_TO_STDOUT=1"
                "SECRET_KEY_BASE=dummy"
                "HOME=${deploy}"
                "PWD=${deploy}"
                "RAILS_ENV=production"
              ];
              ExposedPorts = {
                  "3000" = {};
              };
            };
        };

        container = pkgs.dockerTools.buildLayeredImage {
          name = "rails-blog";
          tag = "latest";
          contents = [
            rubyEnv
          ];
          # TODO: Non-root user, ideally the app lives in /rails or /run/rails 
          # or /app or whatever and it's symlinked to the nix store path
          # enableFakechroot = true;
          # fakeRootCommands = ''
          #   set -x 
          #   mkdir -p /rails
          #   ln -s ${deploy}/bin/* /rails
          #   chown -R 1000:1000 ${deploy}/bin
          #   chown -R 1000:1000 /rails
          # '';
          # extraCommands = ''
          #   whoami
          #   chgrp -R 0 /rails
          #   chmod -R g+rwX /rails
          # '';
          config = {
            Cmd = [ "${rubyEnv}/bin/bundle" "exec" "rails" "server" "-b" "0.0.0.0"];
            # TODO: There is behavior difference between ${rubyEnv/bin/bundle},
            # /bin/bundle, ${deploy}/bin/bundle, ${deploy}/bin/rails s, etc. 
            # Cmd = [ "bundle" "exec" "rails" "server" "-b" "0.0.0.0"];
            WorkingDir = "${deploy}";
            Env = [
              "RAILS_LOG_TO_STDOUT=1"
              "SECRET_KEY_BASE=dummy"
              "HOME=${deploy}"
              "PWD=${deploy}"
              "RAILS_ENV=production"
            ];
            ExposedPorts = {
                "3000" = {};
            };
          };
        };
        packages.nix2container = othercontainer;
        packages.default = container;
        devShells = rec {
          default = dev;
          dev = pkgs.mkShell {
            buildInputs =
              [
                rubyEnv
                bundixcli
                bundleLock
                bundleUpdate
              ]
              ++ (with pkgs; [
                yarn
                rufo
                # more packages here
              ]);
          };
        };
      }
    );
}
