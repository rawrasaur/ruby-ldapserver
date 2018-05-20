require 'ldap/server/connection'
require 'ldap/server/operation'
require 'openssl'
require 'logger'

module LDAP
class Server

  DEFAULT_OPT = {
      :port=>389,
      :nodelay=>true,
  }

  # Create a new server. Options include all those to tcpserver/preforkserver
  # plus:
  #   :operation_class=>Class			- set Operation handler class
  #   :operation_args=>[...]			- args to Operation.new
  #   :ssl_key_file=>pem, :ssl_cert_file=>pem	- enable SSL
  #   :ssl_ca_path=>directory			- verify peer certificates
  #   :schema=>Schema				- Schema object
  #   :namingContexts=>[dn, ...]		- base DN(s) we answer
  
  attr_reader :logger

  def initialize(opt = DEFAULT_OPT)
    @opt = opt
    @opt[:server] = self
    @opt[:operation_class] ||= LDAP::Server::Operation
    @opt[:operation_args] ||= []
    unless @opt[:logger]
       @opt[:logger] ||= Logger.new($stderr)
       @opt[:logger].level = Logger::INFO
    end
    @logger = @opt[:logger]
    LDAP::Server.ssl_prepare(@opt)
    @schema = opt[:schema]	# may be nil
  end

  # create opt[:ssl_ctx] from the other ssl options

  def self.ssl_prepare(opt) # :nodoc:
    if opt[:ssl_key_file] and opt[:ssl_cert_file]
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key = OpenSSL::PKey::RSA.new(File::read(opt[:ssl_key_file]))
      ctx.cert = OpenSSL::X509::Certificate.new(File::read(opt[:ssl_cert_file]))
      if opt[:ssl_dhparams]
        ctx.tmp_dh_callback = proc { |*args|
            OpenSSL::PKey::DH.new(
              File.read(opt[:ssl_dhparams])
            )
        }
      end
      if opt[:ssl_ca_path]
        ctx.ca_path = opt[:ssl_ca_path]
        ctx.verify_mode = opt[:ssl_verify_mode] ||
          OpenSSL::SSL::VERIFY_PEER|OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      elsif opt[:ssl_verify_mode] != 0
        $stderr.puts "Warning: No ssl_ca_path, peer certificate won't be verified"
      end
      opt[:ssl_ctx] = ctx
    end
  end

  def run_tcpserver
    require 'ldap/server/tcpserver'

    opt = @opt
    @thread = LDAP::Server.tcpserver(@opt) do
      LDAP::Server::Connection::new(self,opt).handle_requests
    end
  end

  def run_prefork
    require 'ldap/server/preforkserver'

    opt = @opt
    @thread = LDAP::Server.preforkserver(@opt) do
      LDAP::Server::Connection::new(self,opt).handle_requests
    end
  end

  def join
    @thread.join
  end

  def stop
    @thread.raise Interrupt, "" # <= temporary fix for 1.8.6
    begin
      @thread.join
    rescue Interrupt
      # nop
    end
  end

end # class Server
end # module LDAP
