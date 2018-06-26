require 'spec_helper'
require 'puppetserver/ca/cli'

require 'tmpdir'
require 'stringio'
require 'fileutils'
require 'openssl'

RSpec.describe Puppetserver::Ca::Cli do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def create_cert(subject_key, name, signer_key = nil, signer_cert = nil)
    cert = OpenSSL::X509::Certificate.new

    signer_cert ||= cert
    signer_key ||= subject_key

    cert.public_key = subject_key.public_key
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.issuer = signer_cert.subject
    cert.version = 2
    cert.serial = rand(2**128)
    cert.not_before = Time.now - 1
    cert.not_after = Time.now + 360000
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.issuer_certificate = signer_cert
    ef.subject_certificate = cert

    [
      ["basicConstraints", "CA:TRUE", true],
      ["keyUsage", "keyCertSign, cRLSign", true],
      ["subjectKeyIdentifier", "hash", false],
      ["authorityKeyIdentifier", "keyid:always", false]
    ].each do |ext|
      extension = ef.create_extension(*ext)
      cert.add_extension(extension)
    end

    cert.sign(signer_key, OpenSSL::Digest::SHA256.new)

    return cert
  end

  def create_crl(cert, key, certs_to_revoke = [])
    crl = OpenSSL::X509::CRL.new
    crl.version = 1
    crl.issuer = cert.subject
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.issuer_certificate = cert
    ef.subject_certificate = cert
    certs_to_revoke.each do |c|
      revoked = OpenSSL::X509::Revoked.new
      revoked.serial = c.serial
      revoked.time = Time.now
      revoked.add_extension(
        OpenSSL::X509::Extension.new(
          "CRLReason",
          OpenSSL::ASN1::Enumerated(
            OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE)))

      crl.add_revoked(revoked)
    end
    crl.add_extension(
      ef.create_extension(["authorityKeyIdentifier", "keyid:always", false]))
    crl.add_extension(
      OpenSSL::X509::Extension.new("crlNumber",
                                   OpenSSL::ASN1::Integer(certs_to_revoke.length)))
    crl.last_update = Time.now - 1
    crl.next_update = Time.now + 360000
    crl.sign(key, OpenSSL::Digest::SHA256.new)

    return crl
  end

  def with_files_in(tmpdir, &block)
    bundle_file = File.join(tmpdir, 'bundle.pem')
    key_file = File.join(tmpdir, 'key.pem')
    chain_file = File.join(tmpdir, 'chain.pem')

    not_before = Time.now - 1

    root_key = OpenSSL::PKey::RSA.new(1024)
    root_cert = create_cert(root_key, 'foo')

    leaf_key = OpenSSL::PKey::RSA.new(1024)
    File.open(key_file, 'w') do |f|
      f.puts leaf_key.to_pem
    end

    leaf_cert = create_cert(leaf_key, 'bar', root_key, root_cert)

    File.open(bundle_file, 'w') do |f|
      f.puts leaf_cert.to_pem
      f.puts root_cert.to_pem
    end

    root_crl = create_crl(root_cert, root_key)
    leaf_crl = create_crl(leaf_cert, leaf_key)

    File.open(chain_file, 'w') do |f|
      f.puts leaf_crl.to_pem
      f.puts root_crl.to_pem
    end


    block.call(bundle_file, key_file, chain_file)
  end

  shared_examples 'basic cli args' do |subcommand, usage|
    it 'responds to a --help flag' do
      args = [subcommand, '--help'].compact
      exit_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stdout.string).to match(usage)
      expect(exit_code).to be 0
    end

    it 'prints the help output & returns 1 if no input is given' do
      args = [subcommand].compact
      exit_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stderr.string).to match(usage)
      expect(exit_code).to be 1
    end

    it 'prints the version' do
      semverish = /\d+\.\d+\.\d+(-[a-z0-9._-]+)?/
      args = [subcommand, '--version'].compact
      first_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stdout.string).to match(semverish)
      expect(stderr.string).to be_empty
      expect(first_code).to be 0
    end
  end

  describe 'general options' do
    include_examples 'basic cli args',
      nil,
      /.*Usage: puppetserver ca <command> .*This general help output.*/m
  end

  describe 'the setup subcommand' do
    let(:usage) do
      /.*Usage: puppetserver ca setup.*This setup specific help output.*/m
    end

    include_examples 'basic cli args',
      'setup',
      /.*Usage: puppetserver ca setup.*This setup specific help output.*/m

    it 'does not print the help output if called correctly' do
      Dir.mktmpdir do |tmpdir|
        with_files_in tmpdir do |bundle, key, chain|
          exit_code = Puppetserver::Ca::Cli.run!(['setup',
                                                  '--cert-bundle', bundle,
                                                  '--private-key', key,
                                                  '--crl-chain', chain],
                                                stdout, stderr)
          expect(stderr.string).to be_empty
          expect(exit_code).to be 0
        end
      end
    end

    context 'validation' do
      it 'requires both the --cert-bundle and --private-key options' do
        exit_code = Puppetserver::Ca::Cli.run!(
                      ['setup', '--private-key', 'foo'],
                      stdout,
                      stderr)
        expect(stderr.string).to include('Missing required argument')
        expect(stderr.string).to match(usage)
        expect(exit_code).to be 1

        exit_code = Puppetserver::Ca::Cli.run!(
                      ['setup', '--cert-bundle', 'foo'],
                      stdout,
                      stderr)
        expect(stderr.string).to include('Missing required argument')
        expect(stderr.string).to match(usage)
        expect(exit_code).to be 1
      end

      it 'warns when no CRL is given' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key],
                          stdout,
                          stderr)
            expect(stderr.string).to include('Full CRL chain checking will not be possible')
          end
        end
      end

      it 'requires cert-bundle, private-key, and crl-chain to be readable' do
        # All errors are surfaced from validations
        Dir.mktmpdir do |tmpdir|
          exit_code = Puppetserver::Ca::Cli.run!(
                        ['setup',
                         '--cert-bundle', File.join(tmpdir, 'cert_bundle.pem'),
                         '--private-key', File.join(tmpdir, 'private_key.pem'),
                         '--crl-chain', File.join(tmpdir, 'crl_chain.pem')],
                        stdout, stderr)
          expect(stderr.string).to match(/Could not read .*cert_bundle.pem/)
          expect(stderr.string).to match(/Could not read .*private_key.pem/)
          expect(stderr.string).to match(/Could not read .*crl_chain.pem/)
          expect(exit_code).to be 1
        end
      end

      it 'validates all certs in bundle are parseable' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(bundle, 'a') do |f|
              f.puts '-----BEGIN CERTIFICATE-----'
              f.puts 'garbage'
              f.puts '-----END CERTIFICATE-----'
            end
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*bundle.pem/)
            expect(stderr.string).to include('garbage')
          end
        end
      end

      it 'validates that there are certs in the bundle' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(bundle, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not detect .*bundle.pem/)
          end
        end
      end

      it 'validates the private key' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(key, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*key.pem/)
          end
        end
      end

      it 'validates the private key and leaf cert match' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(key, 'w') {|f| f.puts OpenSSL::PKey::RSA.new(1024).to_pem }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to include('Private key and certificate do not match')
          end
        end
      end

      it 'validates all crls in chain are parseable' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(chain, 'a') do |f|
              f.puts '-----BEGIN X509 CRL-----'
              f.puts 'garbage'
              f.puts '-----END X509 CRL-----'
            end
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*chain.pem/)
            expect(stderr.string).to include('garbage')
          end
        end
      end

      it 'validates that there are crls in the chain, if given chain' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(chain, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not detect .*chain.pem/)
          end
        end
      end

      it 'validates the leaf crl and leaf cert match' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            crls = File.read(chain).scan(/----BEGIN X509 CRL----.*?----END X509 CRL----/m)

            baz_key = OpenSSL::PKey::RSA.new(1024)
            baz_cert = create_cert(baz_key, 'baz')
            baz_crl = create_crl(baz_cert, baz_key)

            File.open(chain, 'w') do |f|
              f.puts baz_crl.to_pem
              f.puts crls[1..-1]
            end

            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to include('Leaf CRL was not issued by leaf certificate')
          end
        end
      end

      it 'validates that leaf cert is valid wrt the provided chain/bundle' do
        Dir.mktmpdir do |tmpdir|
          bundle_file = File.join(tmpdir, 'bundle.pem')
          key_file = File.join(tmpdir, 'key.pem')
          chain_file = File.join(tmpdir, 'chain.pem')

          root_key = OpenSSL::PKey::RSA.new(1024)
          leaf_key = OpenSSL::PKey::RSA.new(1024)

          File.open(key_file, 'w') do |f|
            f.puts leaf_key.to_pem
          end

          root_cert = create_cert(root_key, 'foo')
          leaf_cert = create_cert(leaf_key, 'bar', root_key, root_cert)

          File.open(bundle_file, 'w') do |f|
            f.puts leaf_cert.to_pem
            f.puts root_cert.to_pem
          end

          # This should ensure the leaf cert is revoked
          root_crl = create_crl(root_cert, root_key, [leaf_cert])
          leaf_crl = create_crl(leaf_cert, leaf_key)

          File.open(chain_file, 'w') do |f|
            f.puts leaf_crl.to_pem
            f.puts root_crl.to_pem
          end

          exit_code = Puppetserver::Ca::Cli.run!(['setup',
                                                  '--private-key', key_file,
                                                  '--cert-bundle', bundle_file,
                                                  '--crl-chain', chain_file],
                                                  stdout,
                                                  stderr)

          expect(stderr.string).to include('Leaf certificate could not be validated')
        end
      end
    end
  end
end
