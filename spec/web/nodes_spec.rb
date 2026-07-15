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
    @nodes.expects(:list).returns(NODES_TEST_DATA.map(&:dup))
    app.set(:nodes, @nodes)
    # Wire a fresh cache for every test so datatables requests go through the
    # cache while still calling @nodes.list exactly once (on the cold miss).
    app.set(:node_list_cache, Oxidized::API::NodeListCache.new(@nodes))
  end

  describe '/nodes.?:format?' do
    it 'shows all nodes' do
      get '/nodes.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 6
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

FakeNodeObj = Struct.new(:name, :group, :stats, :output_class) do
  def output = output_class
end

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

  it 'returns 200 with an error message for an invalid regex' do
    post '/nodes/conf_search', { 'search_in_conf_textbox' => '[invalid(' }

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include 'Invalid search expression'
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
