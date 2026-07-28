require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/url_for'
require 'tilt/haml'
require 'htmlentities'
require 'charlock_holmes'
require 'timeout'
module Oxidized
  module API
    require 'oxidized/web/version'

    class WebApp < Sinatra::Base
      helpers Sinatra::UrlForHelper
      set :public_folder, proc { File.join(root, 'public') }
      set :haml, { escape_html: false }
      set :conf_search_mutex, Mutex.new
      set :conf_search_threads, 1

      get '/' do
        redirect url_for('/nodes')
      end

      get '/favicon.ico' do
        redirect url_for('/images/favicon.ico')
      end

      # Server-side DataTables endpoint for the nodes listing page.
      # Accepts standard DataTables server-side processing parameters so that
      # only one page of data is fetched, filtered, and sorted per request
      # instead of sending every node to the browser at once.
      #
      # Query parameters (sent automatically by DataTables):
      #   draw             - request counter echoed back in the response
      #   start            - index of the first record for this page
      #   length           - number of records per page (-1 = all)
      #   search[value]    - global search string
      #   order[0][column] - index of the column to sort by (0-based)
      #   order[0][dir]    - sort direction: "asc" or "desc"
      #
      # Optional base filters (used by the /nodes/group/<x> and
      # /nodes/model/<x> pages so those views are paginated server-side too,
      # instead of rendering every matching host into the HTML):
      #   group  - only return nodes in this group ("default" == ungrouped)
      #   model  - only return nodes of this model
      #
      # Returns JSON in the DataTables server-side format:
      #   { draw, recordsTotal, recordsFiltered, data: [...] }
      get '/nodes/datatables' do
        content_type :json
        dt = datatables_params

        # Use the node list cache so that Nodes#list (which serialises every
        # node while holding the global mutex) is not called on every AJAX
        # request.  #enrich_node merges rather than mutates so the cached
        # hashes are never modified by concurrent requests.
        all_nodes = node_list_cache.list.map { |node| enrich_node(node) }

        # Optional base filter by group or model, applied before search and
        # pagination.  enrich_node normalises a missing group to "default", so
        # a plain equality check also matches ungrouped nodes for group=default.
        # A present-but-empty value (e.g. "?group=") is treated as "no filter"
        # rather than "match the empty group", which would return nothing.
        if (group = params[:group]) && !group.empty?
          all_nodes = all_nodes.select { |node| node[:group].to_s == group }
        elsif (model = params[:model]) && !model.empty?
          all_nodes = all_nodes.select { |node| node[:model].to_s == model }
        end

        records_total = all_nodes.count

        # Apply global search across the visible text columns
        unless dt[:search].empty?
          s = dt[:search].downcase
          all_nodes = all_nodes.select do |node|
            %i[name ip model group status].any? { |f| node[f].to_s.downcase.include?(s) }
          end
        end

        records_filtered = all_nodes.count

        # Sort – use numeric comparison for time columns, string for the rest
        col_fields = %i[name ip model group status time mtime]
        sort_field = col_fields[dt[:order_col]] || :name
        sorted = if %i[time mtime].include?(sort_field)
                   all_nodes.sort_by { |node| node[sort_field].is_a?(Time) ? node[sort_field].to_i : 0 }
                 else
                   all_nodes.sort_by { |node| node[sort_field].to_s.downcase }
                 end
        sorted.reverse! if dt[:order_dir] == 'desc'

        # Paginate (length == -1 means "all records")
        page_data = dt[:length] == -1 ? sorted : (sorted.slice(dt[:start], dt[:length]) || [])

        # The failure reason lives on the live node objects, not in the cached
        # serialized list, so look it up separately and attach it to the page.
        errors = error_cache.map

        json(
          draw: dt[:draw],
          recordsTotal: records_total,
          recordsFiltered: records_filtered,
          data: page_data.map { |node| serialize_node_for_table(node, errors) }
        )
      end

      # Server-side DataTables endpoint for the /nodes/stats page.
      #
      # Defined *before* /nodes/:filter/* so that "stats" is not swallowed as a
      # filter name.  Uses the stats cache so the per-node summary rows are
      # computed at most once per TTL window rather than on every AJAX request.
      get '/nodes/stats/datatables' do
        content_type :json
        dt = datatables_params

        rows = stats_cache.rows
        records_total = rows.count

        unless dt[:search].empty?
          s = dt[:search].downcase
          rows = rows.select do |row|
            %i[name status total_runs failures failure_rate avg_time].any? do |f|
              row[f].to_s.downcase.include?(s)
            end
          end
        end
        records_filtered = rows.count

        col_fields = %i[name total_runs failures failure_rate avg_time status last_success last_failure]
        sort_field = col_fields[dt[:order_col]] || :name
        sorted =
          case sort_field
          when :last_success, :last_failure
            rows.sort_by { |row| row[sort_field].is_a?(Time) ? row[sort_field].to_i : 0 }
          when :total_runs, :failures, :failure_rate, :avg_time
            rows.sort_by { |row| row[sort_field].to_f }
          else
            rows.sort_by { |row| row[sort_field].to_s.downcase }
          end
        sorted.reverse! if dt[:order_dir] == 'desc'

        page_data = dt[:length] == -1 ? sorted : (sorted.slice(dt[:start], dt[:length]) || [])

        json(
          draw: dt[:draw],
          recordsTotal: records_total,
          recordsFiltered: records_filtered,
          data: page_data.map { |row| serialize_stats_row(row) }
        )
      end

      # :filter can be "group" or "model"
      # URL: /nodes/group/<GroupName>[.json]
      # URL: /nodes/model/<ModelName>[.json]
      #
      # HTML: renders the standard nodes table in server-side mode, pushing the
      #   filter down to /nodes/datatables so only one page of matching hosts is
      #   ever loaded – large groups/models no longer send every row.
      # .json: returns the full filtered list (unchanged, for API consumers).
      #
      # as GroupName can include /, we use splat to match its value
      # and extract the optional ".json" with route_parse
      get '/nodes/:filter/*' do
        value, @json = route_parse params[:splat].first
        filter = params[:filter]

        if @json || params[:format] == 'json'
          @data = filtered_nodes(filter, value)
        else
          @server_side  = true
          @filter_type  = filter
          @filter_value = value
        end
        out :nodes
      end

      get '/nodes.?:format?' do
        if params[:format] == 'json'
          # JSON consumers (scripts, API clients) still get the full list
          @data = node_list_cache.list.map { |node| enrich_node(node) }
        else
          # HTML view: use server-side DataTables so only one page of data is
          # fetched per request.  The actual data is loaded via AJAX by the
          # browser calling /nodes/datatables with DataTables parameters.
          @server_side = true
        end
        out :nodes
      end

      post '/nodes/conf_search.?:format?' do
        @search_term = params[:search_in_conf_textbox].to_s
        redirect url_for('/nodes') if @search_term.empty?

        # regex search is the default; the search form on the results page
        # sends 'off' (via a hidden field) when the checkbox is unticked
        @regex_search = params[:search_regex_checkbox] != 'off'
        # preserve the existing case-sensitive default; the search form sends
        # 'off' (via a hidden field) when the checkbox is unticked
        @case_sensitive_search = params[:search_case_sensitive_checkbox] != 'off'
        @nodes_match = []
        begin
          pattern = @regex_search ? @search_term : Regexp.escape(@search_term)
          options = @case_sensitive_search ? 0 : Regexp::IGNORECASE
          @to_research = Regexp.new pattern, options
        rescue RegexpError => e
          @error = "Invalid regular expression: #{e.message}"
        end

        if @error
          status 400
          @data = { error: @error }
        else
          @nodes_match = search_configs(@to_research)
          @data = @nodes_match
        end
        out :conf_search
      end

      get '/nodes/stats.?:format?' do
        if params[:format] == 'json'
          # Keep the top-level shape a JSON object keyed by node name (as the
          # previous implementation did) so existing consumers can still index
          # by node name; the per-node value is now a structured summary.
          @data = stats_cache.rows.each_with_object({}) do |row, acc|
            acc[row[:name].to_s] = serialize_stats_row(row)
          end
          json @data
        else
          # HTML view: server-side DataTables, data loaded via AJAX from
          # /nodes/stats/datatables one page at a time.
          @server_side = true
          out :stats
        end
      end

      get '/reload.?:format?' do
        node = params[:node]
        node ? (nodes.load node) : nodes.load
        # Discard the cached data so the next request reflects the reload
        node_list_cache.invalidate!
        stats_cache.invalidate!
        error_cache.invalidate!
        @data = node ? "reloaded #{node}" : 'reloaded list of nodes'
        out
      end

      # URL: /node/fetch/<group>/<node>.json
      # Gets the configuration of a node
      # <group> is optional. If no group is given, nil will be passed to oxidized
      # .json is optional. If given, will return the output in json format
      get '/node/fetch/?*?/:node' do
        node, @json = route_parse :node
        group = params['splat'].first
        group = nil if group.empty?
        begin
          @data = nodes.fetch node, group
        rescue NodeNotFound => e
          @data = e.message
        end
        out :text
      end

      # URL: /node/fetch/<group>/<node>[.json]
      # <group> is optional, and not used
      # .json is optional. If given, will return 'ok'
      # if not, it redirects to /nodes
      get '/node/next/?*?/:node' do
        node, @json = route_parse :node
        nodes.next node
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      # use this to attach author/email/message to commit
      put '/node/next/?*?/:node' do
        node, @json = route_parse :node
        opt = JSON.parse request.body.read
        nodes.next node, opt
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      get '/node/show/:node' do
        node, @json = route_parse :node
        @data = filter_node_vars(nodes.show(node))
        out :node
      end

      # display the versions of a node
      # URL: /node/version[.json]?node_full=<GroupName/NodeName>
      get '/node/version.?:format?' do
        @data = nil
        @group = nil
        @node = nil
        node_full = params[:node_full]
        if node_full.include? '/'
          node_full = node_full.rpartition("/")
          @group = node_full[0]
          @node = node_full[2]
          @data = nodes.version @node, @group
        else
          @node = node_full
          @data = nodes.version @node, nil
        end
        out :versions
      end

      # show the blob of a version
      get '/node/version/view.?:format?' do
        node, @json = route_parse :node
        @info = {
          node: node,
          group: params[:group],
          oid: params[:oid],
          time: Time.at(params[:epoch].to_i),
          num: params[:num]
        }

        the_data = nodes.get_version node, @info[:group], @info[:oid]
        if %w[json text].include?(params[:format])
          @data = the_data
        else
          utf8_encoded_content = convert_to_utf8(the_data)
          @data = HTMLEntities.new.encode(utf8_encoded_content)
        end
        out :version
      end

      # show diffs between 2 version
      get '/node/version/diffs' do
        node, @json = route_parse :node
        @data = nil
        @info = { node: node,
                  group: params[:group],
                  oid: params[:oid],
                  time: Time.at(params[:epoch].to_i),
                  num: params[:num],
                  num2: (params[:num].to_i - 1) }
        group = nil
        group = @info[:group] if @info[:group] != ''
        @oids_dates = nodes.version node, group
        if params[:oid2]
          @info[:oid2] = params[:oid2]
          oid2 = nil
          num = @oids_dates.count + 1
          @oids_dates.each do |x|
            num -= 1
            next unless x[:oid].to_s == params[:oid2]

            oid2 = x[:oid]
            @info[:num2] = num
            break
          end
          @data = nodes.get_diff node, @info[:group], @info[:oid], oid2
        else
          @data = nodes.get_diff node, @info[:group], @info[:oid], nil
        end
        @stat = %w[null null]
        if @data != 'no diffs' && !@data.nil?
          @stat = @data[:stat]
          @data = @data[:patch]
        else
          @data = 'No diff available'
        end
        @diff = diff_view @data
        out :diffs
      end

      # used for diff between 2 distant commit
      post '/node/version/diffs' do
        redirect url_for("/node/version/diffs?node=#{params[:node]}&group=#{params[:group]}&oid=#{params[:oid]}&epoch=#{params[:epoch]}&num=#{params[:num]}&oid2=#{params[:oid2]}")
      end

      # Taken von Haml 5.0, so it still works in 6.0
      HTML_ESCAPE = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;' }.freeze
      HTML_ESCAPE_ONCE_REGEX = /['"><]|&(?!(?:[a-zA-Z]+|#(?:\d+|[xX][0-9a-fA-F]+));)/

      # lines of context shown around each config search match
      CONF_SEARCH_CONTEXT_LINES = 2

      # Limit each node's regular-expression scan so a pathological expression
      # cannot tie up a Puma worker indefinitely.
      CONF_SEARCH_MATCH_TIMEOUT = 2

      # Only these read-only output implementations are known to be safe when
      # separate instances fetch configurations concurrently. GitCrypt is
      # deliberately excluded because each fetch unlocks and locks its shared
      # repository. Unknown/custom outputs are processed serially.
      PARALLEL_CONF_SEARCH_OUTPUTS = %w[
        Oxidized::Output::File
        Oxidized::Output::Git
      ].freeze

      private

      def out(template = :text)
        if @json || (params[:format] == 'json')
          if @data.is_a?(String)
            json @data.lines
          else
            json @data
          end
        elsif (template == :text) || (params[:format] == 'text')
          content_type :text
          @data
        else
          haml template, layout: true
        end
      end

      def nodes
        settings.nodes
      end

      def node_list_cache
        settings.node_list_cache
      end

      def stats_cache
        settings.stats_cache
      end

      def error_cache
        settings.error_cache
      end

      # Extract and normalise the standard DataTables server-side parameters.
      def datatables_params
        {
          draw: params[:draw].to_i,
          start: params[:start].to_i,
          length: params[:length].to_i,
          search: (params.dig('search', 'value') || params.dig(:search, :value)).to_s,
          order_col: (params.dig('order', '0', 'column') || params.dig(:order, :'0', :column)).to_i,
          order_dir: (params.dig('order', '0', 'dir') || params.dig(:order, :'0', :dir) || 'asc').to_s
        }
      end

      # Return a copy of a serialized node hash with the derived display fields
      # (status, time, group) filled in.  Never mutates the input so cached
      # hashes stay pristine across concurrent requests.
      def enrich_node(node)
        node.merge(
          status: node[:last] ? node[:last][:status] : 'never',
          time: node[:last] ? node[:last][:end] : 'never',
          group: node[:group] || 'default'
        )
      end

      # Nodes matching a "group"/"model" filter, enriched for display/JSON.
      def filtered_nodes(filter, value)
        key = filter.to_sym
        node_list_cache.list.each_with_object([]) do |node, acc|
          matches = node[key].to_s == value ||
                    (key == :group && node[:group].nil? && value == 'default')
          acc << enrich_node(node) if matches
        end
      end

      def serialize_node_for_table(node, errors = {})
        status = node[:status].to_s
        row = {
          name: node[:name].to_s,
          full_name: (node[:full_name] || node[:name]).to_s,
          ip: node[:ip].to_s,
          model: node[:model].to_s,
          group: node[:group].to_s,
          status: status,
          time: node[:time].is_a?(Time) ? node[:time].to_i : 0,
          mtime: node[:mtime].is_a?(Time) ? node[:mtime].to_i : 0
        }

        # Only surface the last error while the node is actually failing — the
        # core never clears err_type on a later success, so showing it for a
        # recovered node would be misleading.
        if status == 'no_connection' && (err = errors[row[:name]])
          row[:err_type]   = err[:type]
          row[:err_reason] = err[:reason]
        end

        row
      end

      def serialize_stats_row(row)
        {
          name: row[:name].to_s,
          total_runs: row[:total_runs],
          failures: row[:failures],
          failure_rate: row[:failure_rate],
          avg_time: row[:avg_time],
          status: row[:status].to_s,
          last_success: row[:last_success].is_a?(Time) ? row[:last_success].to_i : 0,
          last_failure: row[:last_failure].is_a?(Time) ? row[:last_failure].to_i : 0,
          row_class: row[:row_class].to_s
        }
      end

      # Build the AJAX URL for the nodes DataTable, pushing any active
      # group/model filter down to the server-side endpoint.  The filter value
      # is percent-encoded so it is safe to embed verbatim in a JS string.
      def nodes_datatables_url
        base = url_for('/nodes/datatables')
        case @filter_type
        when 'group' then "#{base}?group=#{Rack::Utils.escape(@filter_value)}"
        when 'model' then "#{base}?model=#{Rack::Utils.escape(@filter_value)}"
        else base
        end
      end

      # Search every node's stored configuration for +regex+ and return the
      # matches with snippets. Searches are serialized globally so simultaneous
      # requests cannot multiply the worker count. Within a search, only
      # explicitly safe output backends use the bounded worker pool; GitCrypt
      # and unknown/custom outputs remain serial.
      def search_configs(regex)
        settings.conf_search_mutex.synchronize do
          search_config_snapshot(regex)
        end
      end

      def search_config_snapshot(regex)
        # Snapshot without the global Nodes mutex. Array#to_a returns a plain
        # Array copy for the Oxidized::Nodes subclass, keeping the poller free.
        node_objs = nodes.respond_to?(:to_a) ? nodes.to_a : nodes.list
        indexed_nodes = node_objs.each_with_index.map { |node, index| [node, index] }
        concurrent, serial = indexed_nodes.partition do |node, _index|
          parallel_conf_search_safe?(node)
        end

        results = Array.new(node_objs.length)
        parallel_results = parallel_map(concurrent, settings.conf_search_threads) do |node, index|
          [index, search_node_config(node, regex)]
        end
        parallel_results.compact.each { |index, result| results[index] = result }
        serial.each do |node, index|
          results[index] = search_node_config(node, regex)
        end
        results.compact
      end

      def search_node_config(node, regex)
        config = fetch_config_for_search(node)
        return if config.nil?

        config = convert_to_utf8(config.to_s)
        matches = Timeout.timeout(CONF_SEARCH_MATCH_TIMEOUT) do
          config_search_matches(config, regex)
        end
        return if matches.empty?

        {
          node: node_name_of(node),
          full_name: node_full_name_of(node),
          matches: matches
        }
      rescue Timeout::Error
        logger.warn "conf_search: regex timed out for #{node_name_of(node)}"
        nil
      rescue StandardError => e
        logger.warn "conf_search: could not search #{node_name_of(node)}: #{e.class}: #{e.message}"
        nil
      end

      def parallel_conf_search_safe?(node)
        return false unless node.respond_to?(:output)

        output_class = node.output
        return false unless output_class.respond_to?(:ancestors)
        return output_class.conf_search_parallel_safe? if output_class.respond_to?(:conf_search_parallel_safe?)

        output_names = output_class.ancestors.filter_map do |ancestor|
          ancestor.respond_to?(:name) ? ancestor.name : nil
        end
        (output_names & PARALLEL_CONF_SEARCH_OUTPUTS).any?
      rescue StandardError
        false
      end

      # Fetch a node's config without taking the global nodes mutex (which
      # Nodes#fetch would hold for the whole disk/git read, serialising every
      # request and stalling device polling).  Falls back to Nodes#fetch when
      # the object does not expose an output (e.g. in tests).
      def fetch_config_for_search(node)
        if node.respond_to?(:output) && node.respond_to?(:name)
          output = node.output.new
          return nil unless output.respond_to?(:fetch)

          group = node.respond_to?(:group) ? node.group : nil
          output.fetch(node, group)
        else
          name  = node_name_of(node)
          group = if node.respond_to?(:group)
                    node.group
                  else
                    (node.is_a?(Hash) ? node[:group] : nil)
                  end
          nodes.fetch(name, group)
        end
      rescue StandardError => e
        logger.warn "conf_search: could not fetch config for #{node_name_of(node)}: #{e.class}: #{e.message}"
        nil
      end

      def node_name_of(node)
        node.respond_to?(:name) ? node.name : node[:name]
      end

      def node_full_name_of(node)
        if node.respond_to?(:name)
          name  = node.name
          group = node.respond_to?(:group) ? node.group : nil
          group ? "#{group}/#{name}" : name
        else
          node[:full_name] || node[:name]
        end
      end

      # Map over +items+ using a bounded pool of worker threads.  Order is
      # preserved.  A block that raises leaves that slot nil rather than killing
      # the whole map (callers compact the result).
      def parallel_map(items, pool_size)
        items = items.to_a
        return [] if items.empty?

        queue   = Queue.new
        results = Array.new(items.size)
        items.each_with_index { |item, i| queue << [item, i] }

        workers = Array.new([pool_size, items.size].min) do
          Thread.new do
            loop do
              item, i = queue.pop(true)
              begin
                results[i] = yield(item)
              rescue StandardError => e
                logger.warn "parallel_map worker error: #{e.class}: #{e.message}"
                results[i] = nil
              end
            rescue ThreadError
              break # queue empty
            end
          end
        end
        workers.each(&:join)
        results
      end

      # checks if param ends with .json
      # if so, returns param without ".json" and true
      # if not, returns param and false
      def route_parse(param)
        json = false
        e = if param.respond_to?(:to_str)
              param.split '.'
            else
              params[param].split '.'
            end
        if e.last == 'json'
          e.pop
          json = true
        end
        [e.join('.'), json]
      end

      # give one entry per line of config matching regexp, with the 1-based
      # line number and a snippet of the line surrounded by up to
      # CONF_SEARCH_CONTEXT_LINES lines of context on each side
      def config_search_matches(config, regexp)
        lines = config.lines.map(&:chomp)
        matches = []
        lines.each_with_index do |line, index|
          next unless line.match?(regexp)

          from = [index - CONF_SEARCH_CONTEXT_LINES, 0].max
          to = [index + CONF_SEARCH_CONTEXT_LINES, lines.length - 1].min
          snippet = (from..to).map do |i|
            { number: i + 1, text: lines[i], match: i == index }
          end
          matches.push({ line_number: index + 1, snippet: snippet })
        end
        matches
      end

      # HTML-escape line, wrapping every regexp match in <mark>
      def highlight_matches(line, regexp)
        html = +''
        pos = 0
        while pos <= line.length && (md = regexp.match(line, pos))
          if md[0].empty?
            # zero-width match: emit up to and including the character at the
            # match position, so the scan always advances
            html << escape_once(line[pos..md.begin(0)])
            pos = md.begin(0) + 1
          else
            html << escape_once(line[pos...md.begin(0)])
            html << "<mark>#{escape_once(md[0])}</mark>"
            pos = md.end(0)
          end
        end
        html << escape_once(line[pos..].to_s)
        html
      end

      # HTML for one config search snippet: line-numbered text with the
      # matches highlighted
      def snippet_html(match, regexp)
        Timeout.timeout(CONF_SEARCH_MATCH_TIMEOUT) do
          width = match[:snippet].last[:number].to_s.length
          match[:snippet].map do |line|
            number = line[:number].to_s.rjust(width)
            text = if line[:match]
                     highlight_matches(line[:text], regexp)
                   else
                     escape_once(line[:text])
                   end
            "#{number}: #{text}"
          end.join("\n")
        end
      rescue Timeout::Error
        logger.warn "conf_search: regex timed out while rendering a snippet"
        match[:snippet].map do |line|
          "#{line[:number]}: #{escape_once(line[:text])}"
        end.join("\n")
      end

      # give the time elapsed between now and a date (Time object)
      def time_from_now(date)
        return "no time specified" if date.nil?

        raise "time_from_now needs a Time object" unless date.instance_of? Time

        t = (Time.now - date).to_i
        mm, ss = t.divmod(60)
        hh, mm = mm.divmod(60)
        dd, hh = hh.divmod(24)
        if dd.positive?
          "#{dd} days #{hh} hours ago"
        elsif hh.positive?
          "#{hh} hours #{mm} min ago"
        else
          "#{mm} min #{ss} sec ago"
        end
      end

      # method the give diffs in separate view (the old and the new) as in github
      def diff_view(diff)
        old_diff = []
        new_diff = []

        utf8_encoded_content = convert_to_utf8(diff)
        HTMLEntities.new.encode(utf8_encoded_content).each_line do |line|
          if /^\+/.match(line)
            new_diff.push(line)
          elsif /^-/.match(line)
            old_diff.push(line)
          else
            new_diff.push(line)
            old_diff.push(line)
          end
        end

        length_o = old_diff.count
        length_n = new_diff.count
        (0..[length_o, length_n].max).each do |i|
          break if i > [length_o, length_n].min

          if /^-.*/.match(old_diff[i]) && !/^\+.*/.match(new_diff[i])
            # tag removed latter to add color syntax
            # ugly way to avoid asymmetry if at display the line takes 2 line on the screen
            insert = "&nbsp;\n"
            new_diff.insert(i, insert)
            length_n += 1
          elsif !/^-.*/.match(old_diff[i]) && /^\+.*/.match(new_diff[i])
            insert = "&nbsp;\n"
            old_diff.insert(i, insert)
            length_o += 1
          end
        end
        { old_diff: old_diff, new_diff: new_diff }
      end

      def escape_once(text)
        text = text.to_s
        text.gsub(HTML_ESCAPE_ONCE_REGEX, HTML_ESCAPE)
      end

      def convert_to_utf8(text)
        detection = ::CharlockHolmes::EncodingDetector.detect(text)
        if detection[:type] == :text
          ::CharlockHolmes::Converter.convert text, detection[:encoding], 'UTF-8'
        else
          'The text contains binary values - cannot display'
        end
      end

      def filter_node_vars(serialized_node)
        # Make a deep copy of the data, so we do not impact oxidized
        data = Marshal.load(Marshal.dump(serialized_node))
        # Make sure we work on strings (Oxidized <= 0.34.1 uses symbols)
        data[:vars] = data[:vars].transform_keys(&:to_s)

        hide_node_vars = settings.configuration[:hide_node_vars].map(&:to_s)
        if data[:vars].is_a?(Hash) && hide_node_vars&.any?
          hide_node_vars.each do |key|
            data[:vars][key] = '<hidden>' if data[:vars].has_key?(key)
          end
        end

        data
      end
    end
  end
end
