require_relative '../spec_helper'
require 'json'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  NODES_TEST_DATA = [
    { name: 'sw4', ip: '10.10.10.10', model: 'ios', time: 'time', mtime: 'mtime' },
    { name: 'sw5', ip: '10.10.10.5',  model: 'ios', time: 'time', mtime: 'mtime' },
    { name: 'sw6', ip: '10.10.10.6',  model: 'ios', time: 'time', mtime: 'mtime' },
    { name: 'sw7', ip: '10.10.10.7',  model: 'ios', time: 'time', mtime: 'mtime', group: 'group1' },
    { name: 'sw8', ip: '10.10.10.8',  model: 'aos', time: 'time', mtime: 'mtime', group: 'group1' },
    { name: 'sw9', ip: '10.10.10.9',  model: 'aos', time: 'time', mtime: 'mtime', group: 'gr/oup1' }
  ].freeze

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

      result       = JSON.parse(last_response.body)
      groups       = result['data'].map { |n| n['group'] }
      ungrouped    = result['data'].select { |n| %w[sw4 sw5 sw6].include?(n['name']) }
      _(ungrouped.map { |n| n['group'] }.uniq).must_equal ['default']
    end
  end

end

# Unit tests for the NodeListCache class itself.
# These live outside the WebApp describe so they don't inherit its before/mock.
describe Oxidized::API::NodeListCache do
  DATA = [{ name: 'sw1', ip: '1.1.1.1', model: 'ios', mtime: 'mtime' }].freeze

  it 'returns the node list on the first call' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).once.returns(DATA.map(&:dup))
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    result = cache.list
    _(result.first[:name]).must_equal 'sw1'
  end

  it 'does not call nodes.list again within the TTL' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).once.returns(DATA.map(&:dup))  # must be called exactly once
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 60)

    cache.list  # cold miss  → calls nodes.list
    cache.list  # warm hit   → no second call
    # Mocha verifies "exactly once" at test teardown
  end

  it 're-fetches after the TTL expires' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).twice.returns(DATA.map(&:dup))
    cache = Oxidized::API::NodeListCache.new(nodes, ttl: 0)  # TTL=0 → always stale

    cache.list
    sleep 0.01  # ensure time has advanced past ttl=0
    cache.list  # stale → second fetch
  end

  it 're-fetches after the cache is explicitly invalidated' do
    nodes = mock('Oxidized::Nodes')
    nodes.expects(:list).twice.returns(DATA.map(&:dup))
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
