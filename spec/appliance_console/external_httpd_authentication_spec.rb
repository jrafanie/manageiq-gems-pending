require "active_support/all"
require "appliance_console/external_httpd_authentication"
require "appliance_console/prompts"
require "appliance_console/principal"
require "linux_admin"

describe ApplianceConsole::ExternalHttpdAuthentication do
  let(:host) { "this.server.com" }
  subject { described_class.new(host) }

  context "#domain_from_host" do
    it "should be blank for blank" do
      expect(subject.send(:domain_from_host, nil)).to be_blank
    end

    it "should be blank for non fqdn" do
      expect(subject.send(:domain_from_host, "hostonly")).to be_blank
    end

    it "should return first part" do
      expect(subject.send(:domain_from_host, "host.domain.com")).to eq("domain.com")
    end
  end

  context "#fqdn" do
    it "should handle blank values" do
      expect(subject.send(:fqdn, "host", nil)).to eq("host")
      expect(subject.send(:fqdn, nil, "domain.com")).to eq(nil)
    end

    it "should not append to a fqn" do
      expect(subject.send(:fqdn, "host.domain.com", "domain.com")).to eq("host.domain.com")
    end

    it "should append to a short host name" do
      expect(subject.send(:fqdn, "host", "domain.com")).to eq("host.domain.com")
    end
  end

  context "#ask_for_parameters" do
    context "with just hostname" do
      subject do
        Class.new(described_class) do
          include ApplianceConsole::Prompts
        end.new(host)
      end
      it "supports just host (appliance_console use case)" do
        expect(subject).to receive(:say).with(/ipa/i)
        expect(subject).to receive(:just_ask).with(/hostname/i, nil, anything, anything).and_return("ipa")
        expect(subject).to receive(:just_ask).with(/domain/i, "server.com", anything, anything).and_return("server.com")
        expect(subject).to receive(:just_ask).with(/realm/i, "SERVER.COM").and_return("realm.server.com")
        expect(subject).to receive(:just_ask).with(/principal/i, "admin").and_return("admin")
        expect(subject).to receive(:just_ask).with(/password/i, nil).and_return("password")
        expect(subject.ask_for_parameters).to be_truthy
        expect(subject.send(:realm)).to eq("REALM.SERVER.COM")
        # expect(subject.ipaserver).to eq("ipa.server.com")
      end
    end
  end

  context "#enable_kerberos_dns_lookups" do
    let(:all_false_kerberos_config) do
      <<-EOT.strip_heredoc
        [libdefaults]
          default_realm = MY.REALM
          dns_lookup_realm = false
          dns_lookup_kdc = false
          rdns = false
          ticket_lifetime = 24h
          forwardable = yes
          udp_preference_limit = 0
      EOT
    end

    let(:some_false_kerberos_config) do
      <<-EOT.strip_heredoc
        [libdefaults]
          default_realm = MY.REALM
          dns_lookup_realm = false
          dns_lookup_kdc = true
          rdns = false
          ticket_lifetime = 24h
          forwardable = yes
          udp_preference_limit = 0
      EOT
    end

    let(:expected_kerberos_config) do
      <<-EOT.strip_heredoc
        [libdefaults]
          default_realm = MY.REALM
          dns_lookup_realm = true
          dns_lookup_kdc = true
          rdns = false
          ticket_lifetime = 24h
          forwardable = yes
          udp_preference_limit = 0
      EOT
    end

    before do
      @test_kerberos_config = Tempfile.new(subject.class.name.split("::").last.downcase)
      stub_const("ApplianceConsole::ExternalHttpdAuthentication::ExternalHttpdConfiguration::KERBEROS_CONFIG_FILE",
                 @test_kerberos_config.path)
    end

    after do
      FileUtils.rm_f(@test_kerberos_config.path)
    end

    it "saves a backup copy of the kerberos config file" do
      File.open(@test_kerberos_config, "a") do |f|
        f.write(all_false_kerberos_config)
      end

      subject.enable_kerberos_dns_lookups
      expect(File.read("#{@test_kerberos_config.path}.miqbkp")).to eq(all_false_kerberos_config)
    end

    it "updates dns_lookup flags from all false to all true" do
      File.open(@test_kerberos_config, "a") do |f|
        f.write(all_false_kerberos_config)
      end

      subject.enable_kerberos_dns_lookups
      expect(File.read(@test_kerberos_config)).to eq(expected_kerberos_config)
      expect(File.read("#{@test_kerberos_config.path}.miqbkp")).to eq(all_false_kerberos_config)
    end

    it "updates dns_lookup flags from some false to all true" do
      File.open(@test_kerberos_config, "a") do |f|
        f.write(some_false_kerberos_config)
      end

      subject.enable_kerberos_dns_lookups
      expect(File.read(@test_kerberos_config)).to eq(expected_kerberos_config)
      expect(File.read("#{@test_kerberos_config.path}.miqbkp")).to eq(some_false_kerberos_config)
    end

    it "leaves dns_lookup true flags unchanged" do
      File.open(@test_kerberos_config, "a") do |f|
        f.write(expected_kerberos_config)
      end

      subject.enable_kerberos_dns_lookups
      expect(File.read(@test_kerberos_config)).to eq(expected_kerberos_config)
      expect(File.read("#{@test_kerberos_config.path}.miqbkp")).to eq(expected_kerberos_config)
    end
  end

  context "#post_activation" do
    before do
      @spec_name = File.basename(__FILE__).split(".rb").first.freeze
    end

    it "when http is not running it is not restarted" do
      allow(subject).to receive(:say)
      httpd_service = double(@spec_name, :running? => false)
      expect(httpd_service).not_to receive(:restart)
      allow(LinuxAdmin::Service).to receive(:new).with("httpd").and_return(httpd_service)
      sssd_service = double(@spec_name, :restart => double(@spec_name, :enable => true))
      allow(LinuxAdmin::Service).to receive(:new).with("sssd").and_return(sssd_service)
      subject.post_activation
    end
  end

  context "#configure_ipa_http_service" do
    before do
      allow(subject).to receive(:say)
      service = double("Principal")
      allow(ApplianceConsole::Principal).to receive(:new).and_return(service)
      allow(service).to receive(:register)
      allow(service).to receive(:name)
      allow(FileUtils).to receive(:chown)
      allow(FileUtils).to receive(:chmod)
      allow(AwesomeSpawn).to receive(:run!).with("/usr/sbin/ipa-getkeytab", anything)
    end

    it "accept symbol '$' as part of password string" do
      subject.instance_variable_set("@password", "$my_password")
      expect(AwesomeSpawn).to receive(:run!).exactly(1).with("/usr/bin/kinit",
                                                             :params     => ["admin"],
                                                             :stdin_data => "$my_password")
      subject.send(:configure_ipa_http_service)
    end
  end
end
