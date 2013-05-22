require 'yaml'
require 'openssl'
require 'r509/exceptions'
require 'r509/io_helpers'
require 'r509/subject'
require 'r509/private_key'
require 'r509/engine'
require 'fileutils'
require 'pathname'
require 'r509/validation_mixin'

module R509
  # Module to contain all configuration related classes (e.g. CAConfig, CertProfile, SubjectItemPolicy)
  module Config
    # Provides access to configuration profiles
    class CertProfile
      include R509::ValidationMixin

      attr_reader :basic_constraints, :key_usage, :extended_key_usage,
        :certificate_policies, :subject_item_policy, :ocsp_no_check,
        :inhibit_any_policy, :policy_constraints, :name_constraints,
        :ocsp_location, :cdp_location, :ca_issuers_location, :default_md,
        :allowed_mds

      # All hash options for CertProfile are optional.
      # @option opts [Hash] :basic_constraints
      # @option opts [Array] :key_usage
      # @option opts [Array] :extended_key_usage
      # @option opts [Array] :certificate_policies
      # @option opts [Boolean] :ocsp_no_check Sets OCSP No Check extension in the certificate if true
      # @option opts [Integer] :inhibit_any_policy Sets the value of the inhibitAnyPolicy extension
      # @option opts [Hash] :policy_constraints Sets the value of the policyConstriants extension
      # @option opts [Hash] :name_constraints Sets the value of the nameConstraints extension
      # @option opts [R509::Config::SubjectItemPolicy] :subject_item_policy
      # @option opts [String] :default_md (default:SHA1) The hashing algorithm to use.
      # @option opts [Array] :allowed_mds (optional) Array of allowed hashes.
      #  default_md will be automatically added to this list if it isn't already listed.
      # @option opts [Array] :cdp_location array of strings (URLs)
      # @option opts [Array] :ocsp_location array of strings (URLs)
      # @option opts [Array] :ca_issuers_location array of strings (URLs)
      def initialize(opts = {})
        @basic_constraints = validate_basic_constraints opts[:basic_constraints]
        @key_usage = validate_key_usage opts[:key_usage]
        @extended_key_usage = validate_extended_key_usage opts[:extended_key_usage]
        @certificate_policies = validate_certificate_policies opts[:certificate_policies]
        @inhibit_any_policy = validate_inhibit_any_policy opts[:inhibit_any_policy]
        @policy_constraints = validate_policy_constraints opts[:policy_constraints]
        @name_constraints = validate_name_constraints opts[:name_constraints]
        @ocsp_no_check = (opts[:ocsp_no_check] == true or opts[:ocsp_no_check] == "true")?true:false
        @subject_item_policy = validate_subject_item_policy opts[:subject_item_policy]
        @ocsp_location = validate_ocsp_location(opts[:ocsp_location])
        @ca_issuers_location = validate_ca_issuers_location(opts[:ca_issuers_location])
        @cdp_location = validate_cdp_location(opts[:cdp_location])
        @default_md = validate_md(opts[:default_md] || R509::MessageDigest::DEFAULT_MD)
        @allowed_mds = validate_allowed_mds(opts[:allowed_mds])
      end

    end

    # returns information about the subject item policy for a profile
    class SubjectItemPolicy
      attr_reader :required, :optional

      # @param [Hash] hash of required/optional subject items. These must be in OpenSSL shortname format.
      # @example sample hash
      #  {"CN" => "required",
      #  "O" => "required",
      #  "OU" => "optional",
      #  "ST" => "required",
      #  "C" => "required",
      #  "L" => "required",
      #  "emailAddress" => "optional"}
      def initialize(hash={})
        if not hash.kind_of?(Hash)
          raise ArgumentError, "Must supply a hash in form 'shortname'=>'required/optional'"
        end
        @required = []
        @optional = []
        if not hash.empty?
          hash.each_pair do |key,value|
            if value == "required"
              @required.push(key)
            elsif value == "optional"
              @optional.push(key)
            else
              raise ArgumentError, "Unknown subject item policy value. Allowed values are required and optional"
            end
          end
        end
      end

      # @param [R509::Subject] subject
      # @return [R509::Subject] validated version of the subject or error
      def validate_subject(subject)
        # convert the subject components into an array of component names that match
        # those that are on the required list
        supplied = subject.to_a.each do |item|
          @required.include?(item[0])
        end.map do |item|
          item[0]
        end
        # so we can make sure they gave us everything that's required
        diff = @required - supplied
        if not diff.empty?
          raise R509::R509Error, "This profile requires you supply "+@required.join(", ")
        end

        # the validated subject contains only those subject components that are either
        # required or optional
        R509::Subject.new(subject.to_a.select do |item|
          @required.include?(item[0]) or @optional.include?(item[0])
        end)
      end
    end

    # pool of configs, so we can support multiple CAs from a single config file
    class CAConfigPool
      # @option configs [Hash<String, R509::Config::CAConfig>] the configs to add to the pool
      def initialize(configs)
        @configs = configs
      end

      # get all the config names
      def names
        @configs.keys
      end

      # retrieve a particular config by its name
      def [](name)
        @configs[name]
      end

      # @return a list of all the configs in this pool
      def all
        @configs.values
      end

      # Loads the named configuration config from a yaml string.
      # @param [String] name The name of the config within the file. Note
      #  that a single yaml file can contain more than one configuration.
      # @param [String] yaml_data The filename to load yaml config data from.
      def self.from_yaml(name, yaml_data, opts = {})
        conf = YAML.load(yaml_data)
        configs = {}
        conf[name].each_pair do |ca_name, data|
          configs[ca_name] = R509::Config::CAConfig.load_from_hash(data, opts)
        end
        R509::Config::CAConfigPool.new(configs)
      end
    end

    # Stores a configuration for our CA.
    class CAConfig
      include R509::IOHelpers
      extend R509::IOHelpers
      attr_reader :ca_cert, :crl_validity_hours, :crl_start_skew_seconds, :ocsp_chain,
        :ocsp_start_skew_seconds, :ocsp_validity_hours, :crl_number_file,
        :crl_list_file

      # @option opts [R509::Cert] :ca_cert Cert+Key pair
      # @option opts [Integer] :crl_validity_hours (168) The number of hours that
      #  a CRL will be valid. Defaults to 7 days.
      # @option opts [Hash<String, R509::Config::CertProfile>] :profiles
      # @option opts [String] :crl_number_file The file that we will save
      #  the CRL numbers to.
      # @option opts [String] :crl_list_file The file that we will save
      #  the CRL list data to.
      # @option opts [R509::Cert] :ocsp_cert An optional cert+key pair
      # OCSP signing delegate
      # @option opts [Array<OpenSSL::X509::Certificate>] :ocsp_chain An optional array
      #  that constitutes the chain to attach to an OCSP response
      #
      def initialize(opts = {} )
        if not opts.has_key?(:ca_cert) then
          raise ArgumentError, 'Config object requires that you pass :ca_cert'
        end

        @ca_cert = opts[:ca_cert]

        if not @ca_cert.kind_of?(R509::Cert) then
          raise ArgumentError, ':ca_cert must be of type R509::Cert'
        end

        #ocsp data
        if opts.has_key?(:ocsp_cert) and not opts[:ocsp_cert].kind_of?(R509::Cert) and not opts[:ocsp_cert].nil?
          raise ArgumentError, ':ocsp_cert, if provided, must be of type R509::Cert'
        end
        if opts.has_key?(:ocsp_cert) and not opts[:ocsp_cert].nil? and not opts[:ocsp_cert].has_private_key?
          raise ArgumentError, ':ocsp_cert must contain a private key, not just a certificate'
        end
        @ocsp_cert = opts[:ocsp_cert] unless opts[:ocsp_cert].nil?
        @ocsp_chain = opts[:ocsp_chain] if opts[:ocsp_chain].kind_of?(Array)
        @ocsp_validity_hours = opts[:ocsp_validity_hours] || 168
        @ocsp_start_skew_seconds = opts[:ocsp_start_skew_seconds] || 3600

        @crl_validity_hours = opts[:crl_validity_hours] || 168
        @crl_start_skew_seconds = opts[:crl_start_skew_seconds] || 3600
        @crl_number_file = opts[:crl_number_file] || nil
        @crl_list_file = opts[:crl_list_file] || nil



        @profiles = {}
          if opts[:profiles]
          opts[:profiles].each_pair do |name, prof|
            set_profile(name, prof)
          end
        end

      end

      # @return [R509::Cert] either a custom OCSP cert or the ca_cert
      def ocsp_cert
        if @ocsp_cert.nil? then @ca_cert else @ocsp_cert end
      end

      # @param [String] name The name of the profile
      # @param [R509::Config::CertProfile] prof The profile configuration
      def set_profile(name, prof)
        unless prof.is_a?(R509::Config::CertProfile)
          raise TypeError, "profile is supposed to be a R509::Config::CertProfile"
        end
        @profiles[name] = prof
      end

      # @param [String] prof
      # @return [R509::Config::CertProfile] The config profile.
      def profile(prof)
        if !@profiles.has_key?(prof)
          raise R509::R509Error, "unknown profile '#{prof}'"
        end
        @profiles[prof]
      end

      # @return [Integer] The number of profiles
      def num_profiles
        @profiles.count
      end


      ######### Class Methods ##########

      # Load the configuration from a data hash. The same type that might be
      # used when loading from a YAML file.
      # @param [Hash] conf A hash containing all the configuration options
      # @option opts [String] :ca_root_path The root path for the CA. Defaults to
      #  the current working directory.
      def self.load_from_hash(conf, opts = {})
        if conf.nil?
          raise ArgumentError, "conf not found"
        end
        unless conf.kind_of?(Hash)
          raise ArgumentError, "conf must be a Hash"
        end

        ca_root_path = Pathname.new(opts[:ca_root_path] || FileUtils.getwd)

        unless File.directory?(ca_root_path)
          raise R509Error, "ca_root_path is not a directory: #{ca_root_path}"
        end

        ca_cert_hash = conf['ca_cert']

        if ca_cert_hash.has_key?('engine')
          ca_cert = self.load_with_engine(ca_cert_hash,ca_root_path)
        end

        if ca_cert.nil? and ca_cert_hash.has_key?('pkcs12')
          ca_cert = self.load_with_pkcs12(ca_cert_hash,ca_root_path)
        end

        if ca_cert.nil? and ca_cert_hash.has_key?('cert')
          ca_cert = self.load_with_key(ca_cert_hash,ca_root_path)
        end

        if conf.has_key?("ocsp_cert")
          if conf["ocsp_cert"].has_key?('engine')
            ocsp_cert = self.load_with_engine(conf["ocsp_cert"],ca_root_path)
          end

          if ocsp_cert.nil? and conf["ocsp_cert"].has_key?('pkcs12')
            ocsp_cert = self.load_with_pkcs12(conf["ocsp_cert"],ca_root_path)
          end

          if ocsp_cert.nil? and conf["ocsp_cert"].has_key?('cert')
            ocsp_cert = self.load_with_key(conf["ocsp_cert"],ca_root_path)
          end
        end

        ocsp_chain = []
        if conf.has_key?("ocsp_chain")
          ocsp_chain_data = read_data(ca_root_path+conf["ocsp_chain"])
          cert_regex = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
          ocsp_chain_data.scan(cert_regex) do |cert|
            ocsp_chain.push(OpenSSL::X509::Certificate.new(cert))
          end
        end

        opts = {
          :ca_cert => ca_cert,
          :ocsp_cert => ocsp_cert,
          :ocsp_chain => ocsp_chain,
          :crl_validity_hours => conf['crl_validity_hours'],
          :ocsp_validity_hours => conf['ocsp_validity_hours'],
          :ocsp_start_skew_seconds => conf['ocsp_start_skew_seconds'],
        }

        if conf.has_key?("crl_list")
          opts[:crl_list_file] = (ca_root_path + conf['crl_list']).to_s
        end

        if conf.has_key?("crl_number")
          opts[:crl_number_file] = (ca_root_path + conf['crl_number']).to_s
        end


        profs = {}
        conf['profiles'].keys.each do |profile|
          data = conf['profiles'][profile]
          if not data["subject_item_policy"].nil?
            subject_item_policy = R509::Config::SubjectItemPolicy.new(data["subject_item_policy"])
          end
          profs[profile] = R509::Config::CertProfile.new(:key_usage => data["key_usage"],
                             :extended_key_usage => data["extended_key_usage"],
                             :basic_constraints => data["basic_constraints"],
                             :certificate_policies => data["certificate_policies"],
                             :ocsp_no_check => data["ocsp_no_check"],
                             :inhibit_any_policy => data["inhibit_any_policy"],
                             :policy_constraints => data["policy_constraints"],
                             :name_constraints => data["name_constraints"],
                             :cdp_location => data["cdp_location"],
                             :ocsp_location => data["ocsp_location"],
                             :ca_issuers_location => data["ca_issuers_location"],
                             :default_md => data["default_md"],
                             :allowed_mds => data["allowed_mds"],
                             :subject_item_policy => subject_item_policy)
        end unless conf['profiles'].nil?
        opts[:profiles] = profs

        # Create the instance.
        self.new(opts)
      end

      # Loads the named configuration config from a yaml file.
      # @param [String] conf_name The name of the config within the file. Note
      #  that a single yaml file can contain more than one configuration.
      # @param [String] yaml_file The filename to load yaml config data from.
      def self.load_yaml(conf_name, yaml_file, opts = {})
        conf = YAML.load_file(yaml_file)
        self.load_from_hash(conf[conf_name], opts)
      end

      # Loads the named configuration config from a yaml string.
      # @param [String] conf_name The name of the config within the file. Note
      #  that a single yaml file can contain more than one configuration.
      # @param [String] yaml_data The filename to load yaml config data from.
      def self.from_yaml(conf_name, yaml_data, opts = {})
        conf = YAML.load(yaml_data)
        self.load_from_hash(conf[conf_name], opts)
      end

      private

      def self.load_with_engine(ca_cert_hash,ca_root_path)
        if ca_cert_hash.has_key?('key')
          raise ArgumentError, "You can't specify both key and engine"
        end
        if ca_cert_hash.has_key?('pkcs12')
          raise ArgumentError, "You can't specify both engine and pkcs12"
        end
        if not ca_cert_hash.has_key?('key_name')
          raise ArgumentError, "You must supply a key_name with an engine"
        end

        engine = R509::Engine.instance.load(ca_cert_hash['engine'])

        ca_key = R509::PrivateKey.new(
          :engine => engine,
          :key_name => ca_cert_hash['key_name']
        )
        ca_cert_file = ca_root_path + ca_cert_hash['cert']
        ca_cert = R509::Cert.new(
          :cert => read_data(ca_cert_file),
          :key => ca_key
        )
        ca_cert
      end

      def self.load_with_pkcs12(ca_cert_hash,ca_root_path)
        if ca_cert_hash.has_key?('cert')
          raise ArgumentError, "You can't specify both pkcs12 and cert"
        end
        if ca_cert_hash.has_key?('key')
          raise ArgumentError, "You can't specify both pkcs12 and key"
        end

        pkcs12_file = ca_root_path + ca_cert_hash['pkcs12']
        ca_cert = R509::Cert.new(
          :pkcs12 => read_data(pkcs12_file),
          :password => ca_cert_hash['password']
        )
        ca_cert
      end

      def self.load_with_key(ca_cert_hash,ca_root_path)
        ca_cert_file = ca_root_path + ca_cert_hash['cert']

        if ca_cert_hash.has_key?('key')
          ca_key_file = ca_root_path + ca_cert_hash['key']
          ca_key = R509::PrivateKey.new(
            :key => read_data(ca_key_file),
            :password => ca_cert_hash['password']
          )
          ca_cert = R509::Cert.new(
            :cert => read_data(ca_cert_file),
            :key => ca_key
          )
        else
          # in certain cases (OCSP responders for example) we may want
          # to load a ca_cert with no private key
          ca_cert = R509::Cert.new(:cert => read_data(ca_cert_file))
        end
        ca_cert
      end

    end
  end
end
