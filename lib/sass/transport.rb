# frozen_string_literal: true

require 'open3'
require 'observer'
require_relative '../../ext/embedded_sass_pb'

module Sass
  # The interface for communicating with dart-sass-embedded.
  # It handles message serialization and deserialization as well as
  # tracking concurrent request and response
  class Transport
    include Observable

    DART_SASS_EMBEDDED = File.absolute_path(
      "../../ext/sass_embedded/dart-sass-embedded#{Platform::OS == 'windows' ? '.bat' : ''}", __dir__
    )

    PROTOCOL_ERROR_ID = 4_294_967_295

    def initialize
      @stdin_semaphore = Mutex.new
      @observerable_semaphore = Mutex.new
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(DART_SASS_EMBEDDED)
      pipe @stderr, $stderr
      receive
    end

    def send(req, res_id)
      mutex = Mutex.new
      resource = ConditionVariable.new

      req_kind = req.class.name.split('::').last.gsub(/\B(?=[A-Z])/, '_').downcase

      message = EmbeddedProtocol::InboundMessage.new(req_kind => req)

      error = nil
      res = nil

      @observerable_semaphore.synchronize do
        MessageObserver.new self, res_id do |e, r|
          mutex.synchronize do
            error = e
            res = r

            resource.signal
          end
        end
      end

      mutex.synchronize do
        write message.to_proto

        resource.wait(mutex)
      end

      raise error if error

      res
    end

    def close
      delete_observers
      @stdin.close unless @stdin.closed?
      @stdout.close unless @stdout.closed?
      @stderr.close unless @stderr.closed?
      nil
    end

    private

    def receive
      Thread.new do
        loop do
          bits = length = 0
          loop do
            byte = @stdout.readbyte
            length += (byte & 0x7f) << bits
            bits += 7
            break if byte <= 0x7f
          end
          changed
          payload = @stdout.read length
          @observerable_semaphore.synchronize do
            notify_observers nil, EmbeddedProtocol::OutboundMessage.decode(payload)
          end
        rescue Interrupt
          break
        rescue IOError => e
          notify_observers e, nil
          close
          break
        end
      end
    end

    def pipe(readable, writeable)
      Thread.new do
        loop do
          writeable.write readable.read
        rescue Interrupt
          break
        rescue IOError => e
          @observerable_semaphore.synchronize do
            notify_observers e, nil
          end
          close
          break
        end
      end
    end

    def write(payload)
      @stdin_semaphore.synchronize do
        length = payload.length
        while length.positive?
          @stdin.write ((length > 0x7f ? 0x80 : 0) | (length & 0x7f)).chr
          length >>= 7
        end
        @stdin.write payload
      end
    end

    # The observer used to listen on messages from stdout, check if id
    # matches the given request id, and yield back to the given block.
    class MessageObserver
      def initialize(obs, id, &block)
        @obs = obs
        @id = id
        @block = block
        @obs.add_observer self
      end

      def update(error, message)
        if error
          @obs.delete_observer self
          @block.call error, nil
        elsif message.error&.id == Transport::PROTOCOL_ERROR_ID
          @obs.delete_observer self
          @block.call ProtocolError.new(message.error.message), nil
        else
          res = message[message.message.to_s]
          if (res['compilation_id'] || res['id']) == @id
            @obs.delete_observer self
            @block.call error, res
          end
        end
      end
    end
  end
end
