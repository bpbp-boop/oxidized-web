# frozen_string_literal: true

require 'json'
require 'puma'

module Oxidized
  module API
    # Thread-safe cache for Nodes#list.
    #
    # Problem
    # -------
    # Nodes#list in the oxidized core holds the global nodes Mutex for the full
    # duration of serializing every node.  With tens-of-thousands of hosts that
    # can take hundreds of milliseconds and blocks the worker from scheduling
    # device polls during that window.  Without caching, every DataTables AJAX
    # request (page change, search, sort) causes a fresh full serialization.
    #
    # Solution
    # --------
    # Keep a snapshot of the last Nodes#list result and return it to callers
    # until the TTL expires.  Only one thread ever re-fetches from the core at a
    # time (the others wait on the cache's own lightweight mutex and then reuse
    # the freshly-built snapshot).  This reduces Mutex contention on the core
    # nodes object from "once per HTTP request" to "once per TTL window".
    #
    # The cache is invalidated explicitly when /reload is called so the UI
    # always reflects a manual reload immediately.
    #
    # Configuration (extensions.oxidized-web or legacy "rest"):
    #   node_cache_ttl: 10   # seconds between full re-fetches (default 10)
    class NodeListCache
      include SemanticLogger::Loggable

      # Default number of seconds before the cached snapshot is considered stale
      # and a new Nodes#list call is made.
      DEFAULT_TTL = 10

      def initialize(nodes, ttl: DEFAULT_TTL)
        @nodes      = nodes
        @ttl        = ttl
        @mutex      = Mutex.new
        @data       = nil
        @fetched_at = Time.at(0)
      end

      # Return a cached snapshot of Nodes#list, refreshing it when the TTL has
      # elapsed.  Concurrent callers wait on a lightweight mutex; after the
      # first caller refreshes the cache the rest use the new snapshot without
      # re-calling Nodes#list.
      def list
        @mutex.synchronize do
          if stale?
            logger.debug "Node list cache miss — refreshing (ttl=#{@ttl}s)"
            @data       = @nodes.list
            @fetched_at = Time.now
          end
          @data
        end
      end

      # Discard the cached snapshot so the next call to #list fetches fresh data
      # from the oxidized core.  Called when the operator triggers a reload via
      # the web UI or API.
      def invalidate!
        @mutex.synchronize do
          logger.debug "Node list cache invalidated"
          @data       = nil
          @fetched_at = Time.at(0)
        end
      end

      private

      def stale?
        @data.nil? || (Time.now - @fetched_at) > @ttl
      end
    end

    class Web
      include SemanticLogger::Loggable

      attr_reader :thread

      DEFAULT_HOST       = '127.0.0.1'
      DEFAULT_PORT       = 8888
      DEFAULT_URI_PREFIX = ''

      # Number of Puma worker threads.  The default Puma::Server.new has no
      # thread pool configured, which can leave it effectively single-threaded
      # for request handling.  These defaults give headroom for concurrent
      # requests without being excessive.
      DEFAULT_MIN_THREADS = 1
      DEFAULT_MAX_THREADS = 8

      def initialize(nodes, configuration)
        require 'oxidized/web/webapp'
        @configuration = self.class.parse_configuration(configuration)

        cache = NodeListCache.new(
          nodes,
          ttl: @configuration[:node_cache_ttl]
        )

        WebApp.set :nodes,           nodes
        WebApp.set :node_list_cache, cache
        WebApp.set :configuration,   @configuration
        WebApp.set :host_authorization, {
          permitted_hosts: @configuration[:vhosts]
        }
        uri_prefix = @configuration[:uri_prefix]
        @app = Rack::Builder.new do
          map uri_prefix do
            run WebApp
          end
        end
      end

      def run
        min_threads = @configuration[:min_threads]
        max_threads = @configuration[:max_threads]
        @thread = Thread.new do
          @server = Puma::Server.new @app
          @server.min_threads = min_threads
          @server.max_threads = max_threads
          addr = @configuration[:addr]
          port = @configuration[:port]
          @server.add_tcp_listener addr, port
          logger.info "Oxidized-web server listening on #{addr}:#{port} " \
                      "(puma threads: #{min_threads}–#{max_threads}, " \
                      "node cache ttl: #{@configuration[:node_cache_ttl]}s)"
          @server.run.join
        end
      end

      def self.parse_configuration(configuration)
        if configuration.instance_of? Asetus::ConfigStruct
          parse_new_configuration(configuration)
        else
          parse_legacy_configuration(configuration)
        end
      end

      # New configuration style: extensions.oxidized-web
      def self.parse_new_configuration(configuration)
        hide_node_vars = configuration.hide_node_vars? || []
        unless hide_node_vars.is_a?(Array)
          logger.error "hide_node_vars must be a list of strings"
          hide_node_vars = []
        end
        hide_node_vars = hide_node_vars.map(&:to_sym)
        {
          addr:            configuration.listen?     || DEFAULT_HOST,
          port:            configuration.port?       || DEFAULT_PORT,
          uri_prefix:      normalize_uri(configuration.url_prefix? || DEFAULT_URI_PREFIX),
          vhosts:          configuration.vhosts?     || [],
          hide_node_vars:  hide_node_vars,
          node_cache_ttl:  (configuration.node_cache_ttl? || NodeListCache::DEFAULT_TTL).to_i,
          min_threads:     (configuration.min_threads?    || DEFAULT_MIN_THREADS).to_i,
          max_threads:     (configuration.max_threads?    || DEFAULT_MAX_THREADS).to_i
        }
      end

      # Legacy configuration style: "rest: 127.0.0.1:8888/prefix"
      def self.parse_legacy_configuration(configuration)
        listen, uri_prefix = configuration.split('/', 2)
        addr, _, port = listen.rpartition ':'
        unless port
          port = addr
          addr = nil
        end
        {
          addr:            addr,
          port:            port.to_i,
          uri_prefix:      normalize_uri(uri_prefix || DEFAULT_URI_PREFIX),
          vhosts:          [],
          hide_node_vars:  [],
          node_cache_ttl:  NodeListCache::DEFAULT_TTL,
          min_threads:     DEFAULT_MIN_THREADS,
          max_threads:     DEFAULT_MAX_THREADS
        }
      end

      def self.normalize_uri(uri_prefix)
        return '/' if uri_prefix.empty?

        uri_prefix.start_with?('/') ? uri_prefix : "/#{uri_prefix}"
      end
    end
  end
end
