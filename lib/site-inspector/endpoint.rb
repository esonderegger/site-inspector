class SiteInspector
  # Every domain has four possible "endpoints" to evaluate
  #
  # For example, if you had `example.com` you'd have:
  #   1. `http://example.com`
  #   2. `http://www.example.com`
  #   3. `https://example.com`
  #   4. `https://www.example.com`
  #
  # Because each of the four endpoints could potentially respond differently
  # We must evaluate all four to make certain determination
  class Endpoint
    attr_accessor :host, :uri

    # Initatiate a new Endpoint object
    #
    # endpoint - (string) the endpoint to query (e.g., `https://example.com`)
    def initialize(host)
      @uri = Addressable::URI.parse(host.downcase)
      @host = uri.host.sub(/^www\./, "")
      @checks = {}
    end

    def www?
      !!(uri.host =~ /^www\./)
    end

    def root?
      !www?
    end

    def https?
      https.scheme?
    end

    def http?
      !https?
    end

    def scheme
      @uri.scheme
    end

    def request(options = {})
      target = options[:path] ? URI.join(uri, options.delete(:path)) : uri
      request = Typhoeus::Request.new(target, SiteInspector.typhoeus_defaults.merge(options))
      hydra.queue(request)
      hydra.run
      request.response
    end

    # Makes a GET request of the given host
    #
    # Retutns the Typhoeus::Response object
    def response
      @response ||= request
    end

    # Does the server return any response? (including 50x)
    def response?
       response.code != 0 && !timed_out?
    end

    def response_code
      response.response_code.to_s if response
    end

    def timed_out?
      response && response.timed_out?
    end

    # Does the endpoint return a 2xx or 3xx response code?
    def up?
      response && response_code.start_with?("2") || response_code.start_with?("3")
    end

    def down?
      !up?
    end

    # If the domain is a redirect, what's the first endpoint we're redirected to?
    def redirect
      return unless response && response_code.start_with?("3")

      @redirect ||= begin
        redirect = Addressable::URI.parse(headers["location"])

        # This is a relative redirect, but we still need the absolute URI
        if redirect.relative?
          redirect.path = "/#{redirect.path}" unless redirect.path[0] == "/"
          redirect.host = host
          redirect.scheme = scheme
        end

        # This was a redirect to a subpath or back to itself, which we don't care about
        return if redirect.host == host && redirect.scheme == scheme

        # Init a new endpoint representing the redirect
        Endpoint.new(redirect.to_s)
      end
    end

    # Does this endpoint return a redirect?
    def redirect?
      !!redirect
    end

    # What's the effective URL of a request to this domain?
    def resolves_to
      return self unless redirect?
      @resolves_to ||= begin
        response = request(:followlocation => true)

        # Workaround for Webmock not playing nicely with Typhoeus redirects
        if response.mock?
          if response.headers["Location"]
            url = response.headers["Location"]
          else
            url = response.request.url
          end
        else
          url = response.effective_url
        end

        Endpoint.new(url)
      end
    end

    def external_redirect?
      host != resolves_to.host
    end

    def to_s
      uri.to_s
    end

    def inspect
      "#<SiteInspector::Endpoint uri=\"#{uri.to_s}\">"
    end

    # Returns information about the endpoint
    #
    # By default, all checks are run. If one or more check names are passed
    # in the options hash, only those checks will be run.
    #
    # options:
    #   a hash of check symbols and bools representing which checks should be run
    #
    # Returns the hash representing the endpoint and its checks
    def to_h(options={})
      hash = {
        uri: uri.to_s,
        host: host,
        www: www?,
        https: https?,
        scheme: scheme,
        up: up?,
        timed_out: timed_out?,
        redirect: redirect?,
        external_redirect: external_redirect?,
      }

      # Either they've specifically asked for a check, or we throw everything at them
      checks = SiteInspector::Endpoint.checks.select { |c| options.keys.include?(c.name) }
      checks = SiteInspector::Endpoint.checks if checks.empty?

      checks.each do |check|
        hash[check.name] = self.send(check.name).to_h
      end

      hash
    end

    def self.checks
      ObjectSpace.each_object(Class).select { |klass| klass < Check }
    end

    def method_missing(method_sym, *arguments, &block)
      if check = SiteInspector::Endpoint.checks.find { |c| c.name == method_sym }
        @checks[method_sym] ||= check.new(self)
      else
        super
      end
    end

    def respond_to?(method_sym, include_private = false)
      if checks.keys.include?(method_sym)
        true
      else
        super
      end
    end

    private

    def hydra
      SiteInspector.hydra
    end
  end
end
