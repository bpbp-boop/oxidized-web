require_relative '../spec_helper'
require 'json'

NODES_TEST_DATA = [
  { name: 'sw4', ip: '10.10.10.10', model: 'ios', time: 'time', mtime: 'mtime' },
  { name: 'sw5', ip: '10.10.10.5',  model: 'ios', time: 'time', mtime: 'mtime' },
  { name: 'sw6', ip: '10.10.10.6',  model: 'ios', time: 'time', mtime: 'mtime' },
  { name: 'sw7', ip: '10.10.10.7',  model: 'ios', time: 'time', mtime: 'mtime', group: 'group1' },
  { name: 'sw8', ip: '10.10.10.8',  model: 'aos', time: 'time', mtime: 'mtime', group: 'group1' },
  { name: 'sw9', ip: '10.10.10.9',  model: 'aos', time: 'time', mtime: 'mtime', group: 'gr/oup1' }
].freeze

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    @nodes.stubs(:list).returns(NODES_TEST_DATA.map(&:dup))
    # The datatables endpoint also looks up per-node error info off the live
    # node objects; none of the base fixtures carry an error.
    @nodes.stubs(:to_a).returns(NODES_TEST_DATA.map(&:dup))
    app.set(:nodes, @nodes)
    # Wire a fresh cache for every test so datatables requests go through the
    # cache while still calling @nodes.list exactly once (on the cold miss).
    app.set(:node_list_cache, Oxidized::API::NodeListCache.new(@nodes))
    app.set(:error_cache, Oxidized::API::ErrorCache.new(@nodes))
  end

  describe '/nodes.?:format?' do
    it 'shows all nodes' do
      get '/nodes.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 6
    end
  end

  describe '/nodes/conf_search.?:format?' do
    before do
      config = [
        'interface ge-0/0/0',
        '  description uplink to core',
        '  mtu 9000',
        'interface ge-0/0/1',
        '  description access port',
        'system {',
        '  host-name sw4',
        '}'
      ].join("\n")
      @nodes.stubs(:fetch).returns('no match here')
      @nodes.stubs(:fetch).with('sw4', nil).returns(config)
    end

    it 'lists only nodes whose configuration matches' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'description'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 1
      _(result[0]['node']).must_equal 'sw4'
    end

    it 'returns a snippet with two lines of context around each match' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'description'

      matches = JSON.parse(last_response.body)[0]['matches']
      _(matches.length).must_equal 2

      first = matches[0]
      _(first['line_number']).must_equal 2
      _(first['snippet'].map { |l| l['number'] }).must_equal [1, 2, 3, 4]
      _(first['snippet'][1]['match']).must_equal true
      _(first['snippet'][1]['text']).must_equal '  description uplink to core'
      _(first['snippet'][0]['match']).must_equal false

      second = matches[1]
      _(second['line_number']).must_equal 5
      _(second['snippet'].map { |l| l['number'] }).must_equal [3, 4, 5, 6, 7]
    end

    it 'highlights the matched text in the html view' do
      post '/nodes/conf_search', search_in_conf_textbox: 'description'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include '<mark>description</mark>'
    end

    it 'treats the search term as a regular expression by default' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'ge-0/0/.'

      result = JSON.parse(last_response.body)
      _(result.length).must_equal 1
      _(result[0]['matches'].map { |m| m['line_number'] }).must_equal [1, 4]
    end

    it 'treats the search term as literal text when regex is unticked' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'ge-0/0/.',
                                      search_regex_checkbox: 'off'

      result = JSON.parse(last_response.body)
      _(result.length).must_equal 0
    end

    it 'treats the search term as case-sensitive by default' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'DESCRIPTION'

      result = JSON.parse(last_response.body)
      _(result.length).must_equal 0
    end

    it 'matches case-insensitively when case sensitivity is unticked' do
      post '/nodes/conf_search.json', search_in_conf_textbox: 'DESCRIPTION',
                                      search_case_sensitive_checkbox: 'off'

      result = JSON.parse(last_response.body)
      _(result.length).must_equal 1
      _(result[0]['matches'].map { |m| m['line_number'] }).must_equal [2, 5]
    end

    it 'pre-fills the search form with the term and checkbox state' do
      post '/nodes/conf_search', search_in_conf_textbox: 'description'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include "value='description'"
      _(last_response.body).must_include "name='search_regex_checkbox'"
      _(last_response.body).must_include "name='search_case_sensitive_checkbox'"
      _(last_response.body).must_match(/<input(?=[^>]*\bid='conf-search-regex')(?=[^>]*\bchecked)[^>]*>/)
      _(last_response.body).must_match(/<input(?=[^>]*\bid='conf-search-case-sensitive')(?=[^>]*\bchecked)[^>]*>/)
    end

    it 'keeps the regex checkbox unticked after a literal search' do
      post '/nodes/conf_search', search_in_conf_textbox: 'description',
                                 search_regex_checkbox: 'off'

      _(last_response.ok?).must_equal true
      _(last_response.body).wont_match(/<input(?=[^>]*\bid='conf-search-regex')(?=[^>]*\bchecked)[^>]*>/)
    end

    it 'keeps the case-sensitive checkbox unticked after an insensitive search' do
      post '/nodes/conf_search', search_in_conf_textbox: 'description',
                                 search_case_sensitive_checkbox: 'off'

      _(last_response.ok?).must_equal true
      _(last_response.body).wont_match(/<input(?=[^>]*\bid='conf-search-case-sensitive')(?=[^>]*\bchecked)[^>]*>/)
    end
  end

  describe '/nodes/:filter/*' do
    it 'shows all nodes of a group' do
      get '/nodes/group/group1.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 2
    end
    it 'shows all nodes of a group with /' do
      get '/nodes/group/gr/oup1.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 1
    end
    it 'shows all nodes of a model' do
      get '/nodes/model/ios.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 4
    end
    it 'shows all nodes of the default group' do
      get '/nodes/group/default.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 3
    end
  end

  describe '/nodes/datatables' do
    it 'returns all nodes with DataTables envelope' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result['draw']).must_equal 1
      _(result['recordsTotal']).must_equal 6
      _(result['recordsFiltered']).must_equal 6
      _(result['data'].length).must_equal 6
    end

    it 'returns expected data fields for each node' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      node   = result['data'].first
      _(node.keys).must_include 'name'
      _(node.keys).must_include 'full_name'
      _(node.keys).must_include 'ip'
      _(node.keys).must_include 'model'
      _(node.keys).must_include 'group'
      _(node.keys).must_include 'status'
      _(node.keys).must_include 'time'
      _(node.keys).must_include 'mtime'
    end

    it 'paginates results with start and length' do
      get '/nodes/datatables', {
        draw: '2', start: '2', length: '3',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result['draw']).must_equal 2
      _(result['recordsTotal']).must_equal 6
      _(result['data'].length).must_equal 3
    end

    it 'filters by search value across name column' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => 'sw7',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result['recordsTotal']).must_equal 6
      _(result['recordsFiltered']).must_equal 1
      _(result['data'].first['name']).must_equal 'sw7'
    end

    it 'filters by search value across group column' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => 'group1',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result['recordsFiltered']).must_equal 2
    end

    it 'sorts results in ascending order by name' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result  = JSON.parse(last_response.body)
      names   = result['data'].map { |n| n['name'] }
      _(names).must_equal names.sort
    end

    it 'sorts results in descending order by name' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'desc'
      }

      result  = JSON.parse(last_response.body)
      names   = result['data'].map { |n| n['name'] }
      _(names).must_equal names.sort.reverse
    end

    it 'assigns default group to nodes without a group' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      result['data'].map { |n| n['group'] }
      ungrouped = result['data'].select { |n| %w[sw4 sw5 sw6].include?(n['name']) }
      _(ungrouped.map { |n| n['group'] }.uniq).must_equal ['default']
    end

    it 'filters by group so only one page of that group is returned' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20', group: 'group1',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      _(result['recordsTotal']).must_equal 2
      _(result['recordsFiltered']).must_equal 2
      _(result['data'].map { |n| n['group'] }.uniq).must_equal ['group1']
    end

    it 'filters by the default group (including ungrouped nodes)' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20', group: 'default',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      _(result['recordsTotal']).must_equal 3
      _(result['data'].map { |n| n['name'] }.sort).must_equal %w[sw4 sw5 sw6]
    end

    it 'filters by model' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20', model: 'aos',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      _(result['recordsTotal']).must_equal 2
      _(result['data'].map { |n| n['model'] }.uniq).must_equal ['aos']
    end

    it 'treats an empty group filter as no filter' do
      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20', group: '',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      result = JSON.parse(last_response.body)
      _(result['recordsTotal']).must_equal 6
    end
  end
end

# Unit tests for the NodeListCache class itself.
# These live outside the WebApp describe so they don't inherit its before/mock.
NODE_CACHE_TEST_DATA = [{ name: 'sw1', ip: '1.1.1.1', model: 'ios', mtime: 'mtime' }].freeze

describe Oxidized::API::NodeListCache do
  it 'returns the node list on the first call' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).once.returns(NODE_CACHE_TEST_DATA.map(&:dup))
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    result = cache.list
    _(result.first[:name]).must_equal 'sw1'
  end

  it 'does not call nodes.list again within the TTL' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).once.returns(NODE_CACHE_TEST_DATA.map(&:dup)) # must be called exactly once
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    cache.list  # cold miss  → calls nodes.list
    cache.list  # warm hit   → no second call
    # Mocha verifies "exactly once" at test teardown
  end

  it 're-fetches after the TTL expires' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).twice.returns(NODE_CACHE_TEST_DATA.map(&:dup))
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 0) # TTL=0 → always stale

    cache.list
    sleep 0.01  # ensure time has advanced past ttl=0
    cache.list  # stale → second fetch
  end

  it 're-fetches after the cache is explicitly invalidated' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).twice.returns(NODE_CACHE_TEST_DATA.map(&:dup))
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    cache.list
    cache.invalidate!
    cache.list  # re-fetches because cache was invalidated
  end

  it 'does not mutate the cached hashes when the caller merges' do
    nodes = mock('Oxidized::Nodes')
    nodes.stubs(:list).returns([{ name: 'sw1', group: nil, last: nil }])
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    # Simulate what the datatables endpoint does: merge without mutating
    first = cache.list.map { |n| n.merge(group: n[:group] || 'default') }
    _(first.first[:group]).must_equal 'default'

    # The cached hash itself must not have been modified
    cached_raw = cache.list.first
    _(cached_raw[:group]).must_be_nil
  end
end

# Test doubles for the stats / config-search server-side views.  These mimic
# the parts of an Oxidized::Node that oxidized-web touches.
class FakeStatsObj
  def initialize(successes, failures)
    @successes = successes
    @failures  = failures
  end

  attr_reader :successes, :failures

  def get(status)
    now = Time.now.utc
    if status == :success && @successes.positive?
      Array.new(@successes) { |i| { start: now, end: now - i, time: 1.0 } }
    elsif status == :no_connection && @failures.positive?
      Array.new(@failures) { |i| { start: now, end: now - 100 - i, time: 2.0 } }
    end
  end
end

class FakeGoodOutput
  def fetch(node, _group) = "hostname #{node.name}\n! managed device"
end

class FakeBadOutput
  def fetch(_node, _group) = raise('simulated fetch failure')
end

class SearchConcurrencyProbe
  attr_reader :maximum

  def initialize
    @current = 0
    @maximum = 0
    @mutex = Mutex.new
  end

  def track
    @mutex.synchronize do
      @current += 1
      @maximum = [@maximum, @current].max
    end
    yield
  ensure
    @mutex.synchronize { @current -= 1 }
  end
end

class FakeParallelOutput
  class << self
    attr_accessor :probe

    def conf_search_parallel_safe? = true
  end

  def fetch(node, _group)
    self.class.probe.track do
      sleep 0.02
      "hostname #{node.name}"
    end
  end
end

class FakeSerialOutput < FakeParallelOutput
  def self.conf_search_parallel_safe? = false
end

FakeNodeObj = Struct.new(:name, :group, :stats, :output_class) do
  def output = output_class
end

# Node double carrying the error accessors the ErrorCache reads.
ErrNodeObj = Struct.new(:name, :err_type, :err_reason)

describe 'Oxidized::API::WebApp server-side views' do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @node_objs = [
      FakeNodeObj.new('sw1', nil,  FakeStatsObj.new(9, 1), FakeGoodOutput),
      FakeNodeObj.new('sw2', 'g1', FakeStatsObj.new(5, 5), FakeGoodOutput),
      FakeNodeObj.new('sw3', 'g1', FakeStatsObj.new(0, 3), FakeBadOutput)
    ]
    @nodes = mock('Oxidized::Nodes')
    @nodes.stubs(:list).returns([{ name: 'sw1', ip: '1.1.1.1', model: 'ios' }])
    @nodes.stubs(:to_a).returns(@node_objs)
    @nodes.stubs(:fetch).returns('hostname fallback')
    app.set(:nodes, @nodes)
    app.set(:node_list_cache, Oxidized::API::NodeListCache.new(@nodes))
    app.set(:stats_cache, Oxidized::API::StatsCache.new(@nodes))
  end

  it 'renders the group view in server-side mode' do
    get '/nodes/group/g1'

    _(last_response.ok?).must_equal true
    _(last_response.body).must_match(/var oxServerSide\s*=\s*true/)
    _(last_response.body).must_include 'nodes/datatables?group=g1'
  end

  it 'renders the model view in server-side mode' do
    get '/nodes/model/ios'

    _(last_response.ok?).must_equal true
    _(last_response.body).must_match(/var oxServerSide\s*=\s*true/)
    _(last_response.body).must_include 'nodes/datatables?model=ios'
  end

  it 'HTML-escapes the filter type in the heading (no reflected XSS)' do
    get '/nodes/XSStest%3Cscript%3E/foo'

    _(last_response.ok?).must_equal true
    _(last_response.body).wont_include 'XSStest<script>'
    _(last_response.body).must_include 'XSStest&lt;script&gt;'
  end

  it 'renders the stats view in server-side mode' do
    get '/nodes/stats'

    _(last_response.ok?).must_equal true
    _(last_response.body).must_match(/serverSide:\s*true/)
    _(last_response.body).must_include 'nodes/stats/datatables'
  end

  it 'returns computed stats rows from /nodes/stats/datatables' do
    get '/nodes/stats/datatables', {
      draw: '1', start: '0', length: '20',
      'search[value]' => '',
      'order[0][column]' => '0', 'order[0][dir]' => 'asc'
    }

    result = JSON.parse(last_response.body)
    _(result['recordsTotal']).must_equal 3
    _(result['data'].length).must_equal 3
    row = result['data'].find { |r| r['name'] == 'sw1' }
    _(row['total_runs']).must_equal 10
    _(row['failures']).must_equal 1
    _(row['status']).must_equal 'success'
  end

  it 'searches stats across the status column, not just the name' do
    get '/nodes/stats/datatables', {
      draw: '1', start: '0', length: '20',
      'search[value]' => 'no_connection',
      'order[0][column]' => '0', 'order[0][dir]' => 'asc'
    }

    result = JSON.parse(last_response.body)
    _(result['recordsFiltered']).must_be :>, 0
    _(result['data'].map { |r| r['status'] }.uniq).must_equal ['no_connection']
  end

  it 'returns /nodes/stats.json keyed by node name' do
    get '/nodes/stats.json'

    _(last_response.ok?).must_equal true
    result = JSON.parse(last_response.body)
    _(result).must_be_kind_of Hash
    _(result.keys.sort).must_equal %w[sw1 sw2 sw3]
    _(result['sw1']['total_runs']).must_equal 10
  end

  it 'finds nodes whose config matches the search' do
    post '/nodes/conf_search', { 'search_in_conf_textbox' => 'hostname' }

    _(last_response.ok?).must_equal true
    # sw1 and sw2 match; sw3 raises during fetch and is skipped, not fatal
    _(last_response.body.scan('bi-cloud-download').size).must_equal 2
  end

  it 'does not abort the search when a node fetch raises' do
    post '/nodes/conf_search', { 'search_in_conf_textbox' => 'managed' }

    _(last_response.ok?).must_equal true
    _(last_response.body.scan('bi-cloud-download').size).must_equal 2
  end

  it 'returns 400 with an error message for an invalid regex' do
    post '/nodes/conf_search', { 'search_in_conf_textbox' => '[invalid(' }

    _(last_response.status).must_equal 400
    _(last_response.body).must_include 'Invalid regular expression'
  end
end

describe 'config search concurrency' do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    app.set(:conf_search_threads, 2)
    app.set(:conf_search_mutex, Mutex.new)
    @nodes = mock('Oxidized::Nodes')
    @nodes.stubs(:list).returns([])
    app.set(:nodes, @nodes)
  end

  it 'caps parallel-safe output fetches at the configured worker count' do
    probe = SearchConcurrencyProbe.new
    FakeParallelOutput.probe = probe
    nodes = Array.new(4) do |index|
      FakeNodeObj.new("parallel#{index}", nil, nil, FakeParallelOutput)
    end
    @nodes.stubs(:to_a).returns(nodes)

    post '/nodes/conf_search.json', search_in_conf_textbox: 'hostname'

    _(last_response.ok?).must_equal true
    _(JSON.parse(last_response.body).length).must_equal 4
    _(probe.maximum).must_equal 2
  end

  it 'keeps outputs that reject parallel fetches serial' do
    probe = SearchConcurrencyProbe.new
    FakeSerialOutput.probe = probe
    nodes = Array.new(4) do |index|
      FakeNodeObj.new("serial#{index}", nil, nil, FakeSerialOutput)
    end
    @nodes.stubs(:to_a).returns(nodes)

    post '/nodes/conf_search.json', search_in_conf_textbox: 'hostname'

    _(last_response.ok?).must_equal true
    _(JSON.parse(last_response.body).length).must_equal 4
    _(probe.maximum).must_equal 1
  end

  it 'skips a node when its regex scan times out' do
    FakeSerialOutput.probe = SearchConcurrencyProbe.new
    node = FakeNodeObj.new('slow', nil, nil, FakeSerialOutput)
    @nodes.stubs(:to_a).returns([node])
    Timeout.expects(:timeout).raises(Timeout::Error)

    post '/nodes/conf_search.json', search_in_conf_textbox: '(a+)+$'

    _(last_response.ok?).must_equal true
    _(JSON.parse(last_response.body)).must_equal []
  end
end

describe Oxidized::API::StatsCache do
  it 'computes a summary row from a node stats object' do
    row = Oxidized::API::StatsCache.build_row('sw1', FakeStatsObj.new(9, 1))

    _(row[:total_runs]).must_equal 10
    _(row[:failures]).must_equal 1
    _(row[:failure_rate]).must_be_close_to 10.0
    _(row[:status]).must_equal 'success'
    _(row[:row_class]).must_equal ''
  end

  it 'flags a high failure rate' do
    row = Oxidized::API::StatsCache.build_row('sw2', FakeStatsObj.new(1, 9))

    _(row[:failure_rate]).must_be_close_to 90.0
    _(row[:row_class]).must_equal 'danger'
  end

  it 'handles a node that has never run without dividing by zero' do
    row = Oxidized::API::StatsCache.build_row('sw3', FakeStatsObj.new(0, 0))

    _(row[:total_runs]).must_equal 0
    _(row[:failure_rate]).must_equal 0.0
    _(row[:avg_time]).must_equal 0.0
  end

  it 'caches rows and recomputes after invalidation' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:to_a).twice.returns([FakeNodeObj.new('sw1', nil, FakeStatsObj.new(1, 0), nil)])
    cache = Oxidized::API::StatsCache.new(nodes, ttl: 60)

    cache.rows # cold miss
    cache.rows # warm hit (no second to_a)
    cache.invalidate!
    cache.rows # recompute
  end
end

DT_PARAMS = {
  draw: '1', start: '0', length: '20',
  'search[value]' => '', 'order[0][column]' => '0', 'order[0][dir]' => 'asc'
}.freeze

describe 'failure reason on the nodes table' do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    now = Time.now.utc
    failing = { name: 'bad1', ip: '10.0.0.1', model: 'ios', mtime: 'mtime',
                last: { start: now, end: now, status: :no_connection, time: 1.0 } }
    ok = { name: 'ok1', ip: '10.0.0.2', model: 'ios', mtime: 'mtime',
           last: { start: now, end: now, status: :success, time: 1.0 } }
    @nodes = mock('Oxidized::Nodes')
    @nodes.stubs(:list).returns([failing.dup, ok.dup])
    # Both live nodes carry an err_type; ok1's is stale (it now succeeds).
    @nodes.stubs(:to_a).returns([
                                  ErrNodeObj.new('bad1', 'Net::SSH::AuthenticationFailed', 'Authentication failed'),
                                  ErrNodeObj.new('ok1', 'Net::SSH::AuthenticationFailed', 'stale error')
                                ])
    app.set(:nodes, @nodes)
    app.set(:node_list_cache, Oxidized::API::NodeListCache.new(@nodes))
    app.set(:error_cache, Oxidized::API::ErrorCache.new(@nodes))
  end

  it 'includes err_type/err_reason for a currently-failing node' do
    get '/nodes/datatables', DT_PARAMS.dup

    result = JSON.parse(last_response.body)
    row = result['data'].find { |r| r['name'] == 'bad1' }
    _(row['status']).must_equal 'no_connection'
    _(row['err_type']).must_equal 'Net::SSH::AuthenticationFailed'
    _(row['err_reason']).must_equal 'Authentication failed'
  end

  it 'does not surface a stale error for a node that now succeeds' do
    get '/nodes/datatables', DT_PARAMS.dup

    result = JSON.parse(last_response.body)
    row = result['data'].find { |r| r['name'] == 'ok1' }
    _(row['status']).must_equal 'success'
    _(row.has_key?('err_type')).must_equal false
  end
end

describe Oxidized::API::ErrorCache do
  it 'maps only nodes that currently carry an error' do
    nodes = mock('Oxidized::Nodes')
    nodes.stubs(:to_a).returns([
                                 ErrNodeObj.new('a', 'Net::SSH::AuthenticationFailed', 'auth failed'),
                                 ErrNodeObj.new('b', nil, nil),
                                 ErrNodeObj.new('c', '', '')
                               ])
    cache = Oxidized::API::ErrorCache.new(nodes, ttl: 60)

    result = cache.map
    _(result.keys).must_equal ['a']
    _(result['a'][:type]).must_equal 'Net::SSH::AuthenticationFailed'
    _(result['a'][:reason]).must_equal 'auth failed'
  end

  it 'caches until invalidated' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:to_a).twice.returns([])
    cache = Oxidized::API::ErrorCache.new(nodes, ttl: 60)

    cache.map # cold miss
    cache.map # warm hit (no second to_a)
    cache.invalidate!
    cache.map # recompute
  end
end

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  describe '/nodes/conf_search.?:format?' do
    it 'redirects to /nodes when the search is empty' do
      post '/nodes/conf_search', search_in_conf_textbox: ''

      _(last_response.redirect?).must_equal true
    end

    it 'rejects an invalid regular expression' do
      post '/nodes/conf_search.json', search_in_conf_textbox: '(',
                                      search_regex_checkbox: 'on'

      _(last_response.status).must_equal 400
      result = JSON.parse(last_response.body)
      _(result['error']).must_match(/Invalid regular expression/)
    end
  end
end
