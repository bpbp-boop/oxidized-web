require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/url_for'
require 'tilt/haml'
require 'htmlentities'
require 'charlock_holmes'
module Oxidized
  module API
    require 'oxidized/web/version'

    class WebApp < Sinatra::Base
      helpers Sinatra::UrlForHelper
      set :public_folder, proc { File.join(root, 'public') }
      set :haml, { escape_html: false }

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
      # Returns JSON in the DataTables server-side format:
      #   { draw, recordsTotal, recordsFiltered, data: [...] }
      get '/nodes/datatables' do
        content_type :json

        draw       = params[:draw].to_i
        start_idx  = params[:start].to_i
        length     = params[:length].to_i
        search_val = (params.dig('search', 'value') || params.dig(:search, :value)).to_s
        order_col  = (params.dig('order', '0', 'column') || params.dig(:order, :'0', :column)).to_i
        order_dir  = (params.dig('order', '0', 'dir')    || params.dig(:order, :'0', :dir) || 'asc').to_s

        all_nodes = nodes.list.map do |node|
          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end

        records_total = all_nodes.count

        # Apply global search across the visible text columns
        unless search_val.empty?
          s = search_val.downcase
          all_nodes = all_nodes.select do |node|
            %i[name ip model group status].any? { |f| node[f].to_s.downcase.include?(s) }
          end
        end

        records_filtered = all_nodes.count

        # Sort – use numeric comparison for time columns, string for the rest
        col_fields = %i[name ip model group status time mtime]
        sort_field = col_fields[order_col] || :name
        sorted = if %i[time mtime].include?(sort_field)
                   all_nodes.sort_by { |node| node[sort_field].is_a?(Time) ? node[sort_field].to_i : 0 }
                 else
                   all_nodes.sort_by { |node| node[sort_field].to_s.downcase }
                 end
        sorted.reverse! if order_dir == 'desc'

        # Paginate (length == -1 means "all records")
        page_data = length == -1 ? sorted : (sorted.slice(start_idx, length) || [])

        json(
          draw:            draw,
          recordsTotal:    records_total,
          recordsFiltered: records_filtered,
          data:            page_data.map do |node|
            {
              name:      node[:name].to_s,
              full_name: (node[:full_name] || node[:name]).to_s,
              ip:        node[:ip].to_s,
              model:     node[:model].to_s,
              group:     node[:group].to_s,
              status:    node[:status].to_s,
              time:      node[:time].is_a?(Time)  ? node[:time].to_i  : 0,
              mtime:     node[:mtime].is_a?(Time) ? node[:mtime].to_i : 0
            }
          end
        )
      end

      # :filter can be "group" or "model"
      # URL: /nodes/group/<GroupName>[.json]
      # URL: /nodes/model/<ModelName>[.json]
      # an optional .json extension returns the data as JSON
      #
      # as GroupName can include /, we use splat to match its value
      # and extract the optional ".json" with route_parse
      get '/nodes/:filter/*' do
        value, @json = route_parse params[:splat].first
        @data = nodes.list.select do |node|
          next unless node[params[:filter].to_sym] == value ||
                      (
                        params[:filter].to_sym == :group &&
                        node[params[:filter].to_sym].nil? &&
                        value.to_sym == :default
                      )

          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end
        out :nodes
      end

      get '/nodes.?:format?' do
        if params[:format] == 'json'
          # JSON consumers (scripts, API clients) still get the full list
          @data = nodes.list.map do |node|
            node[:status] = 'never'
            node[:time]   = 'never'
            node[:group]  = 'default' unless node[:group]
            if node[:last]
              node[:status] = node[:last][:status]
              node[:time]   = node[:last][:end]
            end
            node
          end
        else
          # HTML view: use server-side DataTables so only one page of data is
          # fetched per request.  The actual data is loaded via AJAX by the
          # browser calling /nodes/datatables with DataTables parameters.
          @server_side = true
        end
        out :nodes
      end

      post '/nodes/conf_search.?:format?' do
        @to_research = Regexp.new params[:search_in_conf_textbox]
        nodes_list = nodes.list.map
        @nodes_match = []
        nodes_list.each do |n|
          node, @json = route_parse n[:name]
          config = nodes.fetch node, n[:group]
          @nodes_match.push({ node: n[:name], full_name: n[:full_name] }) if config[@to_research]
        end
        @data = @nodes_match
        out :conf_search
      end

      get '/nodes/stats.?:format?' do
        @data = {}
        nodes.each do |node|
          @data[node.name] = node.stats
        end
        out :stats
      end

      get '/reload.?:format?' do
        node = params[:node]
        node ? (nodes.load node) : nodes.load
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
