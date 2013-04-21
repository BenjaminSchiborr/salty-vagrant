require 'json'
require 'yaml'

module VagrantPlugins
  module Salt
    class Provisioner < Vagrant.plugin("2", :provisioner)
    
      def provision
        prepare_pillar
        upload_configs
        upload_keys
        run_bootstrap_script

        if @config.seed_master and @config.install_master
          seed_master
        end

        if @config.accept_keys
          @machine.env.ui.warn "ATTENTION: 'salt.accept_keys' is deprecated. Please use salt.seed_master to upload your minion keys"
          accept_keys
        end

        call_highstate
      end

      def seed_master
        @machine.env.ui.info 'Uploading %d keys to /etc/salt/pki/master/minions/' % config.seed_master.length
        staged_keys = accepted_keys
        @config.seed_master.each do |name, keyfile|
          if staged_keys.include? name
            @machine.env.ui.warn "Accepting staged key: %s" %name
            @machine.communicate.sudo("salt-key -a %s" %name)
            next
          end
          sourcepath = expanded_path(keyfile).to_s
          dest = '/tmp/seed-%s.pub' %name 
          
          @machine.communicate.upload(sourcepath, dest)   
          @machine.communicate.sudo("mv /tmp/seed-%s.pub /etc/salt/pki/master/minions/%s" %[name, name])   
        end
      end

      # Return a list of accepted keys
      def accepted_keys
        out = @machine.communicate.sudo("salt-key -l acc --out json") do |type, output|
          begin
            if type == :stdout
              out = JSON::load(output)
              break out['minions']
            end
          end
        end
        return out
      end
      
      ## Utilities
      def expanded_path(rel_path)
        Pathname.new(rel_path).expand_path(@machine.env.root_path)
      end

      def binaries_found
        ## Determine States, ie: install vs configure
        desired_binaries = []
        if !@config.no_minion
          desired_binaries.push('salt-minion')
          desired_binaries.push('salt-call')
        end

        if @config.install_master
          desired_binaries.push('salt-master')
        end

        if @config.install_syndic
          desired_binaries.push('salt-syndic')
        end

        found = true
        for binary in desired_binaries
          @machine.env.ui.info "Checking if %s is installed" % binary
          if !@machine.communicate.test("which %s" % binary)
            @machine.env.ui.info "%s was not found." % binary
            found = false
          else
            @machine.env.ui.info "%s found" % binary
          end
        end

        return found
      end

      def need_configure
        @config.minion_config or @config.minion_key
      end

      def need_install
        if @config.always_install
          return true
        else
          return !binaries_found()
        end
      end

      def temp_config_dir
        return @config.temp_config_dir || "/tmp"
      end

      # Generates option string for bootstrap script
      def bootstrap_options(install, configure, config_dir)
        options = ""

        ## Any extra options passed to bootstrap
        if @config.bootstrap_options
          options = "%s %s" % [options, @config.bootstrap_options]
        end

        if configure
          options = "%s -c %s" % [options, config_dir]
        end

        if configure and !install
          options = "%s -C" % options
        else

          if @config.install_master
            options = "%s -M" % options
          end

          if @config.install_syndic
            options = "%s -S" % options
          end

          if @config.no_minion
            options = "%s -N" % options
          end

          if @config.install_type
            options = "%s %s" % [options, @config.install_type]
          end

          if @config.install_args
            options = "%s %s" % [options, @config.install_args]
          end
        end

        if @config.verbose
          @machine.env.ui.info "Using Bootstrap Options: %s" % options
        end

        return options
      end

      ## Actions
      # Export pillar data
      def prepare_pillar
        prepkeys = lambda do |hash|
          h = {}
          hash.each do |k, v|
            h.merge!(k.to_s => (v.is_a?(Hash) ? prepkeys[v] : v))
          end
        end

        # Convert to YAML and remove some extra stuff that may get added in
        cleanyaml = lambda do |data|
          prepkeys[data].to_yaml.
            gsub("!ruby/symbol ", ":").
            gsub("---", "").
            gsub(/! (['"])/, '\1').
            gsub(/^( +)-/, '\1  -').
            split("\n").
            map(&:rstrip).
            reject!(&:empty?).
            join("\n")
        end

        # Get the pillar path
        root = File.expand_path(@config.pillar_root || "salt/roots/pillar")
        minion = '*' # This probably should be configurable

        # Grab the existing top.sls file data
        top = Hash.new{ |h, k| h[k] = Hash.new(&h.default_proc) }.
          merge!(YAML.load(File.open(File.join(root, "top.sls"))) || {})

        # Clean out existing generated Pillar data
        if top['base'][minion].is_a?(Array)
          FileUtils.rm_r(File.join(root, "_gen"))
          top['base'][minion].delete_if{ |m| m =~ /^_gen/ }
        end

        # Write out each pillar file and save top.sls changes
        @config.pillar_data.each_with_index do |(file, data), idx|
          @machine.env.ui.info "[salt:pillar] Generating data in #{file}.sls..."

          top['base'][minion].is_a?(Array) ?
            top['base'][minion] |= ["_gen/#{file}"] :
            top['base'][minion]  = ["_gen/#{file}"]

          FileUtils.mkdir_p(File.join(root, "_gen"))
          File.open(File.join(root, "_gen/#{file}.sls"), "w") do |f|
            f.write(cleanyaml[data])
          end

          # Write changes to top.sls if needed
          if idx == @config.pillar_data.size - 1
            @machine.env.ui.info "[salt:pillar] Updating top.sls..."
            File.open(File.join(root, "top.sls"), "w") do |f|
              f.write(cleanyaml[top])
            end
          end
        end
      end

      # Copy master and minion configs to VM
      def upload_configs
        if @config.minion_config
          @machine.env.ui.info "Copying salt minion config to vm."
          @machine.communicate.upload(expanded_path(@config.minion_config).to_s, temp_config_dir + "/minion")
        end

        if @config.master_config
          @machine.env.ui.info "Copying salt master config to vm."
          @machine.communicate.upload(expanded_path(@config.master_config).to_s, temp_config_dir + "/master")
        end
      end

      # Copy master and minion keys to VM
      def upload_keys
        if @config.minion_key and @config.minion_pub
          @machine.env.ui.info "Uploading minion keys."
          @machine.communicate.upload(expanded_path(@config.minion_key).to_s, temp_config_dir + "/minion.pem")
          @machine.communicate.upload(expanded_path(@config.minion_pub).to_s, temp_config_dir + "/minion.pub")
        end

        if @config.master_key and @config.master_pub
          @machine.env.ui.info "Uploading master keys."
          @machine.communicate.upload(expanded_path(@config.master_key).to_s, temp_config_dir + "/master.pem")
          @machine.communicate.upload(expanded_path(@config.master_pub).to_s, temp_config_dir + "/master.pub")
        end
      end

      # Get bootstrap file location, bundled or custom
      def get_bootstrap
        if @config.bootstrap_script
          bootstrap_abs_path = expanded_path(@config.bootstrap_script)
        else
          bootstrap_abs_path = Pathname.new("../../../scripts/bootstrap-salt.sh").expand_path(__FILE__)
        end
        return bootstrap_abs_path
      end

      # Determine if we are configure and/or installing, then do either
      def run_bootstrap_script
        install = need_install()
        configure = need_configure()
        config_dir = temp_config_dir()
        options = bootstrap_options(install, configure, config_dir)

        if configure or install
          if configure and !install
            @machine.env.ui.info "Salt binaries found. Configuring only."
          else
            @machine.env.ui.info "Bootstrapping Salt... (this may take a while)"
          end

          bootstrap_path = get_bootstrap()
          bootstrap_destination = File.join(config_dir, "bootstrap_salt.sh")
          @machine.communicate.upload(bootstrap_path.to_s, bootstrap_destination)
          @machine.communicate.sudo("chmod +x %s" % bootstrap_destination)
          bootstrap = @machine.communicate.sudo("%s %s" % [bootstrap_destination, options]) do |type, data|
            if data[0] == "\n"
              # Remove any leading newline but not whitespace. If we wanted to
              # remove newlines and whitespace we would have used data.lstrip
              data = data[1..-1]
            end
            if @config.verbose
              @machine.env.ui.info(data.rstrip)
            end
          end

          if !bootstrap
            raise Salt::Errors::SaltError, :bootstrap_failed
          end

          if configure and !install
            @machine.env.ui.info "Salt successfully configured!"
          elsif configure and install
            @machine.env.ui.info "Salt successfully configured and installed!"
          elsif !configure and install
            @machine.env.ui.info "Salt successfully installed!"
          end
        else
          @machine.env.ui.info "Salt did not need installing or configuring."
        end
      end
      
      # DEPRECATED
      def accept_keys
        if !@machine.communicate.test("which salt-key")
          @machine.env.ui.info "Salt-key not installed!"
          return 
        end

        key_staged = false

        keys = accepted_keys
        if keys.length > 0
          @machine.env.ui.info "Minion keys registered:"
          keys.each do |name|
            @machine.env.ui.info " - %s" %name
          end
          return
        end

        @machine.env.ui.info "Waiting for minion key..."

        attempts = 0
        while !key_staged
          attempts += 1
          numkeys = @machine.communicate.sudo("salt-key -l pre | wc -l") do |type, rawoutput|
            begin
              if type == :stdout
                output = Integer(rawoutput)
                if output > 1
                  key_staged = true
                end
                break output
              end
            end
          end

          sleep 1
          if attempts > 10
            raise Salt::Errors::SaltError, "No keys staged"
          end
        end

        if key_staged
          @machine.env.ui.info "Adding %s key(s) for minion(s)" %numkeys           
          @machine.communicate.sudo("salt-key -A")
        end
      end
  
      def call_highstate
        if @config.run_highstate
          @machine.env.ui.info "Calling state.highstate... (this may take a while)"
          if @config.install_master
            @machine.communicate.sudo("salt '*' saltutil.sync_all")
            @machine.communicate.sudo("salt '*' state.highstate --verbose") do |type, data|
              if @config.verbose
                @machine.env.ui.info(data)
              end
            end
          else
            @machine.communicate.sudo("salt-call saltutil.sync_all")
            @machine.communicate.sudo("salt-call state.highstate -l debug") do |type, data|
              if @config.verbose
                @machine.env.ui.info(data)
              end
            end
          end
        else
          @machine.env.ui.info "run_highstate set to false. Not running state.highstate."
        end
      end
    end
  end
end
