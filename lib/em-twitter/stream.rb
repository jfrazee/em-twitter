require 'eventmachine'
require 'em/buftok'
require 'uri'
require 'http/parser'
require 'em-twitter/proxy'
require 'em-twitter/request'
require 'em-twitter/response'
require 'em-twitter/decoders/base_decoder'
require 'em-twitter/decoders/gzip_decoder'
require 'eventmachine/reconnectable_connection'

module EventMachine
  module Twitter
    class Stream < ReconnectableConnection

      MAX_LINE_LENGTH = 1024*1024

      attr_reader :host, :port, :headers

      def self.connect(options = {})
        options = DEFAULT_CONNECTION_OPTIONS.merge(options)

        host = options[:host]
        port = options[:port]

        if options[:proxy] && options[:proxy][:uri]
          proxy_uri = URI.parse(options[:proxy][:uri])
          host = proxy_uri.host
          port = proxy_uri.port
        end

        EventMachine.connect(host, port, self, options)
      end

      def initialize(options = {})
        @options            = DEFAULT_CONNECTION_OPTIONS.merge(options)
        @on_inited_callback = options.delete(:on_inited)

        @buffer             = BufferedTokenizer.new("\r", MAX_LINE_LENGTH)
        @parser             = Http::Parser.new(self)
        @request            = Request.new(@options)
        @last_response      = Response.new

        super(:on_unbind => method(:on_unbind), :timeout => @options[:timeout])
      end

      def connection_completed
        start_tls(@options[:ssl]) if @options[:ssl]
        send_data(@request)
      end

      def post_init
        set_comm_inactivity_timeout(@options[:timeout]) if @options[:timeout] > 0
        @on_inited_callback.call if @on_inited_callback
      end

      def receive_data(data)
        @parser << data
      end

      def each_item(&block)
        @each_item_callback = block
      end

      def on_error(&block)
        @error_callback = block
      end

      def on_unauthorized(&block)
        @unauthorized_callback = block
      end

      def on_forbidden(&block)
        @forbidden_callback = block
      end

      def on_not_found(&block)
        @not_found_callback = block
      end

      def on_not_acceptable(&block)
        @not_acceptable_callback = block
      end

      def on_too_long(&block)
        @too_long_callback = block
      end

      def on_range_unacceptable(&block)
        @range_unacceptable_callback = block
      end

      def on_enhance_your_calm(&block)
        @enhance_your_calm_callback = block
      end
      alias :on_rate_limited :on_enhance_your_calm

      def on_reconnect(&block)
        @reconnect_callback = block
      end

      def on_max_reconnects(&block)
        @max_reconnects_callback = block
      end

      def on_close(&block)
        @close_callback = block
      end

      protected

      def handle_error(error)
        @error_callback.call(error) if @error_callback
      end

      def handle_stream(data)
        @last_response = Response.new if @last_response.empty?
        @last_response << @decoder.decode(data)

        @each_item_callback.call(@last_response.body) if @last_response.complete? && @each_item_callback
      end

      def on_unbind
        @close_callback.call if @close_callback
      end

      def on_headers_complete(headers)
        @response_code  = @parser.status_code
        @headers        = headers

        @decoder = if gzip?
          GzipDecoder.new
        else
          BaseDecoder.new
        end

        return if @response_code == 200

        case @response_code
        when 401
          @unauthorized_callback.call if @unauthorized_callback
        when 403
          @forbidden_callback.call if @forbidden_callback
        when 404
          @not_found_callback.call if @not_found_callback
        when 406
          @not_acceptable_callback.call if @not_acceptable_callback
        when 413
          @too_long_callback.call if @too_long_callback
        when 416
          @range_unacceptable_callback.call if @range_unacceptable_callback
        when 420
          @enhance_your_calm_callback.call if @enhance_your_calm_callback
        else
          handle_error("invalid status code: #{@response_code}.")
        end
        EM.stop
      end

      def on_body(data)
        begin
          @buffer.extract(data).each do |line|
            handle_stream(data)
          end
          @last_response.reset if @last_response.complete?
        rescue Exception => e
          handle_error("#{e.class}: " + [e.message, e.backtrace].flatten.join("\n\t"))
          close_connection
          return
        end
      end

      def gzip?
        @headers['Content-Encoding'] && @headers['Content-Encoding'] == 'gzip'
      end

      def network_failure?
        @response_code == 0
      end

    end
  end
end