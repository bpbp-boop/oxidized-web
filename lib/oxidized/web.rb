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

    # Thread-safe cache for the derived per-node statistics shown on
    # /nodes/stats.
    #
    # The stats page used to iterate every node and compute its summary row in
    # the view template on every request, then render one HTML <tr> per host.
    # With tens-of-thousands of hosts that is both slow to compute and lethal
    # for the browser to render.  This cache keeps a snapshot of the computed
    # rows so the /nodes/stats/datatables endpoint can filter, sort and
    # paginate them cheaply (and only ship one page to the browser).
    #
    # Like NodeListCache the snapshot is refreshed at most once per TTL window
    # and can be invalidated explicitly (e.g. on /reload).
    class StatsCache
      include SemanticLogger::Loggable

      DEFAULT_TTL = 10

      def initialize(nodes, ttl: DEFAULT_TTL)
        @nodes      = nodes
        @ttl        = ttl
        @mutex      = Mutex.new
        @data       = nil
        @fetched_at = Time.at(0)
      end

      def rows
        @mutex.synchronize do
          if stale?
            logger.debug "Stats cache miss — recomputing (ttl=#{@ttl}s)"
            # The Stats objects are mutated in place by the polling thread
            # (Stats#add), so a row can occasionally raise while a counter hash
            # or history array is being modified concurrently.  Contain that to
            # the affected node instead of failing the whole stats page; the
            # next refresh will pick it up.
            @data = @nodes.to_a.filter_map do |node|
              self.class.build_row(node.name, node.stats)
            rescue StandardError => e
              logger.warn "Stats cache: skipping node during recompute: #{e.class}: #{e.message}"
              nil
            end
            @fetched_at = Time.now
          end
          @data
        end
      end

      def invalidate!
        @mutex.synchronize do
          logger.debug "Stats cache invalidated"
          @data       = nil
          @fetched_at = Time.at(0)
        end
      end

      # Compute a single summary row from a node's Stats object.  Mirrors the
      # logic that previously lived in views/stats.haml, but returns plain data
      # (Times / numbers) so the endpoint can sort and format it.
      def self.build_row(name, stats)
        successes = stats.successes
        failures  = stats.failures

        last_success, avg_success_time = summarise(stats.get(:success), successes)
        last_failure, avg_failure_time = summarise(stats.get(:no_connection), failures)

        avg_time = if avg_success_time.positive? && avg_failure_time.positive?
                     (avg_success_time + avg_failure_time) / 2
                   elsif avg_success_time.positive?
                     avg_success_time
                   elsif avg_failure_time.positive?
                     avg_failure_time
                   else
                     0.0
                   end

        status = if last_success && last_failure
                   last_success > last_failure ? 'success' : 'no_connection'
                 elsif last_success
                   'success'
                 else
                   'no_connection'
                 end

        total_runs   = successes + failures
        failure_rate = total_runs.zero? ? 0.0 : (failures / total_runs.to_f) * 100
        row_class    = ''
        row_class    = 'warning' if failure_rate >= 50
        row_class    = 'danger'  if failure_rate >= 75

        {
          name: name,
          total_runs: total_runs,
          failures: failures,
          failure_rate: failure_rate,
          avg_time: avg_time,
          status: status,
          last_success: last_success,
          last_failure: last_failure,
          row_class: row_class
        }
      end

      # Given a Stats history array and its counter, return the timestamp of the
      # most recent entry and the average run time over the retained history.
      def self.summarise(history, counter)
        return [nil, 0.0] if Array(history).empty?

        last_time = history.last[:end]
        avg = counter.positive? ? (history.sum { |x| x[:time].to_f } / counter) : 0.0
        [last_time, avg]
      end

      private

      def stale?
        @data.nil? || (Time.now - @fetched_at) > @ttl
      end
    end

    # Thread-safe cache of the last error recorded for each node.
    #
    # The oxidized core stores the reason a backup failed on the live Node
    # object as `err_type` (exception class, e.g. Net::SSH::AuthenticationFailed)
    # and `err_reason` (the message).  These are not part of Node#serialize, so
    # they never reach the web layer via Nodes#list.  This cache reads them
    # directly off the node objects (no serialization, no global mutex) so the
    # nodes table can explain *why* a host is failing.
    #
    # Only the last error is kept and it is never cleared on a subsequent
    # success, so callers must only display it for nodes that are currently in a
    # failing state.
    class ErrorCache
      include SemanticLogger::Loggable

      DEFAULT_TTL = 10

      def initialize(nodes, ttl: DEFAULT_TTL)
        @nodes      = nodes
        @ttl        = ttl
        @mutex      = Mutex.new
        @data       = nil
        @fetched_at = Time.at(0)
      end

      # @return [Hash{String => {type: String, reason: String}}] keyed by node
      #   name; only nodes that currently carry an error are present.
      def map
        @mutex.synchronize do
          if stale?
            @data       = build_map
            @fetched_at = Time.now
          end
          @data
        end
      end

      def invalidate!
        @mutex.synchronize do
          @data       = nil
          @fetched_at = Time.at(0)
        end
      end

      private

      def build_map
        @nodes.to_a.each_with_object({}) do |node, acc|
          next unless node.respond_to?(:err_type)

          type = node.err_type.to_s
          next if type.empty?

          reason = node.respond_to?(:err_reason) ? node.err_reason.to_s : ''
          acc[node.name.to_s] = { type: type, reason: reason }
        end
      end

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
        stats_cache = StatsCache.new(
          nodes,
          ttl: @configuration[:node_cache_ttl]
        )
        error_cache = ErrorCache.new(
          nodes,
          ttl: @configuration[:node_cache_ttl]
        )

        WebApp.set :nodes,           nodes
        WebApp.set :node_list_cache, cache
        WebApp.set :stats_cache,     stats_cache
        WebApp.set :error_cache,     error_cache
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
          # Thread pool counts must be passed to the constructor; Puma::Server
          # exposes min_threads / max_threads as read-only accessors in Puma 6+.
          @server = Puma::Server.new @app, nil,
                                     min_threads: min_threads,
                                     max_threads: max_threads
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
          addr: configuration.listen?     || DEFAULT_HOST,
          port: configuration.port?       || DEFAULT_PORT,
          uri_prefix: normalize_uri(configuration.url_prefix? || DEFAULT_URI_PREFIX),
          vhosts: configuration.vhosts? || [],
          hide_node_vars: hide_node_vars,
          node_cache_ttl: (configuration.node_cache_ttl? || NodeListCache::DEFAULT_TTL).to_i,
          min_threads: (configuration.min_threads?    || DEFAULT_MIN_THREADS).to_i,
          max_threads: (configuration.max_threads?    || DEFAULT_MAX_THREADS).to_i
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
          addr: addr,
          port: port.to_i,
          uri_prefix: normalize_uri(uri_prefix || DEFAULT_URI_PREFIX),
          vhosts: [],
          hide_node_vars: [],
          node_cache_ttl: NodeListCache::DEFAULT_TTL,
          min_threads: DEFAULT_MIN_THREADS,
          max_threads: DEFAULT_MAX_THREADS
        }
      end

      def self.normalize_uri(uri_prefix)
        return '/' if uri_prefix.empty?

        uri_prefix.start_with?('/') ? uri_prefix : "/#{uri_prefix}"
      end
    end
  end
end
