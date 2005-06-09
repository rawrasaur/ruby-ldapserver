require 'thread'
require 'openssl'
require 'ldapserver/result'

module LDAPserver

  # An object which handles an LDAP connection. Note that LDAP allows
  # requests and responses to be exchanged asynchronously: e.g. a client
  # can send three requests, and the three responses can come back in
  # any order. For that reason, we start a new thread for each request,
  # and we need a mutex on the io object so that multiple responses don't
  # interfere with each other.

  class Connection
    attr_reader :binddn, :version, :opt

    def initialize(io, opt={})
      @io = io
      @mutex = Mutex.new
      @active_reqs = {}   # map message ID to thread object
      @binddn = nil
      @version = 3
      @opt = opt
      @logger = opt[:logger] || $stderr
    end

    def log(msg)
      @logger << "[#{@io.peeraddr[3]}]: #{msg}\n"
    end

    # Read one ASN1 element from the given stream.
    # Return String containing the raw element.

    def ber_read(io)
      blk = io.read(2)		# minimum: short tag, short length
      throw(:close) if blk.nil?
      tag = blk[0] & 0x1f
      len = blk[1]

      if tag == 0x1f		# long form
        tag = 0
        while true
          ch = io.getc
          blk << ch
          tag = (tag << 7) | (ch & 0x7f)
          break if (ch & 0x80) == 0
        end
        len = io.getc
        blk << len
      end

      if (len & 0x80) != 0	# long form
        len = len & 0x7f
        raise ProtocolError, "Indefinite length encoding not supported" if len == 0
        offset = blk.length
        blk << io.read(len)
        # is there a more efficient way of doing this?
        len = 0
        blk[offset..-1].each_byte { |b| len = (len << 8) | b }
      end

      offset = blk.length
      blk << io.read(len)
      return blk
      # or if we wanted to keep the partial decoding we've done:
      # return blk, [blk[0] >> 6, tag], offset
    end

    def handle_requests(operationClass, *ocArgs)
      catch(:close) do
        while true
          begin
            blk = ber_read(@io)
            asn1 = OpenSSL::ASN1::decode(blk)
            # Debugging:
            # puts "Request: #{blk.unpack("H*")}\n#{asn1.inspect}" if $debug

            raise ProtocolError, "LDAPMessage must be SEQUENCE" unless asn1.is_a?(OpenSSL::ASN1::Sequence)
            raise ProtocolError, "Bad Message ID" unless asn1.value[0].is_a?(OpenSSL::ASN1::Integer)
            messageId = asn1.value[0].value

            protocolOp = asn1.value[1]
            raise ProtocolError, "Bad protocolOp" unless protocolOp.is_a?(OpenSSL::ASN1::ASN1Data)
            raise ProtocolError, "Bad protocolOp tag class" unless protocolOp.tag_class == :APPLICATION

            # controls are not properly implemented
            c = asn1.value[2]
            if c.is_a?(OpenSSL::ASN1::ASN1Data) and c.tag_class == :APPLICATION and c.tag == 0
              controls = c.value
            end

            case protocolOp.tag
            when 0 # BindRequest
              abandon_all
              @binddn, @version = operationClass.new(self,messageId,*ocArgs).
                                  do_bind(protocolOp, controls)

            when 2 # UnbindRequest
              abandon_all
              throw(:close)

            when 3 # SearchRequest
              # Note: RFC 2251 4.4.4.1 says behaviour is undefined if
              # client sends an overlapping request with same message ID,
              # so we don't have to worry about the case where there is
              # already a thread with this id in @active_reqs.
              # However, to avoid a potential race we copy messageId/
              # protocolOp/controls into thread-local variables, because
              # they will change when the next request comes in.

              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_search(thrp, thrc)
              end

            when 6 # ModifyRequest
              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_modify(thrp, thrc)
              end

            when 8 # AddRequest
              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_add(thrp, thrc)
              end

            when 10 # DelRequest
              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_del(thrp, thrc)
              end

            when 12 # ModifyDNRequest
              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_modifydn(thrp, thrc)
              end

            when 14 # CompareRequest
              @active_reqs[messageId] = Thread.new(messageId,protocolOp,controls) do |thrm,thrp,thrc|
                operationClass.new(self,thrm,*ocArgs).do_compare(thrp, thrc)
              end

            when 16 # AbandonRequest
              abandon(protocolOp.value)

            else
              raise ProtocolError, "Unrecognised protocolOp tag #{protocolOp.tag}"
            end

          rescue ProtocolError, OpenSSL::ASN1::ASN1Error => e
            send_notice_of_disconnection(ProtocolError.new.to_i, e.message)
            throw(:close)

          # all other exceptions propagate up and are caught by tcpserver
          end
        end
      end
    end

    def write(data)
      @mutex.synchronize do
        @io.write(data)
        @io.flush
      end
    end

    def writelock
      @mutex.synchronize do
        yield @io
        @io.flush
      end
    end

    def abandon(messageID)
      @mutex.synchronize do
        thread = @active_reqs.delete(messageID)
        thread.raise Abandon if thread and thread.alive?
      end
    end

    def abandon_all
      @mutex.synchronize do
        @active_reqs.each do |id, thread|
          thread.raise Abandon if thread.alive?
        end
        @active_reqs = {}
      end
    end

    def send_unsolicited_notification(resultCode, opt={})
      protocolOp = [
        OpenSSL::ASN1::Enumerated(resultCode),
        OpenSSL::ASN1::OctetString(opt[:matchedDN] || ""),
        OpenSSL::ASN1::OctetString(opt[:errorMessage] || ""),
      ]
      if opt[:referral]
        rs = opt[:referral].collect { |r| OpenSSL::ASN1::OctetString(r) }
        protocolOp << OpenSSL::ASN1::Sequence(rs, 3, :IMPLICIT, :APPLICATION)
      end
      if opt[:responseName]
        protocolOp << OpenSSL::ASN1::OctetString(opt[:responseName], 10, :IMPLICIT, :APPLICATION)
      end
      if opt[:response]
        protocolOp << OpenSSL::ASN1::OctetString(opt[:response], 11, :IMPLICIT, :APPLICATION)
      end
      message = [
        OpenSSL::ASN1::Integer(0),
        OpenSSL::ASN1::Sequence(protocolOp, 24, :IMPLICIT, :APPLICATION),
      ]
      message << opt[:controls] if opt[:controls]
      write(OpenSSL::ASN1::Sequence(message).to_der)
    end

    def send_notice_of_disconnection(resultCode, errorMessage="")
      send_unsolicited_notification(resultCode,
        :errorMessage=>errorMessage,
        :responseName=>"1.3.6.1.4.1.1466.20036"
      )
    end
  end
end