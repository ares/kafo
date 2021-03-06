# encoding: UTF-8
module Kafo
  class PuppetCommand
    def initialize(command, options = [], puppet_config = nil, configuration = KafoConfigure.config)
      @configuration = configuration
      @command = command
      @puppet_config = puppet_config

      @options = options.push("--modulepath #{modules_path.join(':')}")
      @options.push("--config=#{puppet_config.config_path}") if puppet_config
      @logger  = KafoConfigure.logger
      @puppet_version_check = !configuration.app[:skip_puppet_version_check]
    end

    def command
      @puppet_config.write_config if @puppet_config
      result = [
          manifest,
          '|',
          "RUBYLIB=#{[@configuration.kafo_modules_dir, ::ENV['RUBYLIB']].join(File::PATH_SEPARATOR)}",
          "#{puppet_path} apply #{@options.join(' ')} #{@suffix}",
      ].join(' ')
      @logger.debug result
      result
    end

    def append(suffix)
      @suffix = suffix
      self
    end

    def self.search_puppet_path(bin_name)
      bin_path = (::ENV['PATH'].split(File::PATH_SEPARATOR) + ['/opt/puppetlabs/bin']).find do |path|
        File.executable?(File.join(path, bin_name))
      end
      File.join([bin_path, bin_name].compact)
    end

    private

    def manifest
      %{echo '
        $kafo_config_file="#{@configuration.config_file}"
        #{add_progress}
        #{generate_version_checks.join("\n") if @puppet_version_check}
        #{@command}
      '}
    end

    def add_progress
      %{$kafo_add_progress="#{!KafoConfigure.verbose}"}
    end

    def generate_version_checks
      checks = []
      modules_path.each do |modulepath|
        Dir[File.join(modulepath, '*', 'metadata.json')].sort.each do |metadata_json|
          metadata = JSON.load(File.read(metadata_json))
          next unless metadata['requirements'] && metadata['requirements'].is_a?(Array)

          metadata['requirements'].select { |req| req['name'] == 'puppet' && req['version_requirement'] }.each do |req|
            checks << versioncmp(metadata['name'], req['version_requirement'])
          end
        end
      end
      checks
    end

    def versioncmp(id, version_req)
      # Parse the common ">= x.y < x.y" version requirement to support pre-Puppet 4.5
      # checks with versioncmp. Newer versions use SemVerRange for full support.
      if (version_match = /\A>=\s*([0-9\.]+)(?:\s+<\s*([0-9\.]+))?/.match(version_req))
        minimum = %{minimum => "#{version_match[1]}",}
        maximum = version_match[2] ? %{maximum => "#{version_match[2]}",} : ''
      else
        minimum = ''
        maximum = ''
      end

      # SemVerRange is isolated inside a defined type to prevent parse errors on old versions
      <<-EOS
        if versioncmp($::puppetversion, "4.5.0") >= 0 {
          kafo_configure::puppet_version_semver { "#{id}":
            requirement => "#{version_req}",
          }
        } else {
          kafo_configure::puppet_version_versioncmp { "#{id}":
            #{minimum}
            #{maximum}
          }
        }
      EOS
    end

    def modules_path
      [
          @configuration.module_dirs,
          @configuration.kafo_modules_dir,
      ].flatten
    end

    def puppet_path
      @puppet_path ||= self.class.search_puppet_path('puppet')
    end
  end
end
