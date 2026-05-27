require_relative '../spec_helper'
require 'json'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    @nodes.expects(:list).returns(
      [{ name: 'sw4', ip: '10.10.10.10', model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw5', ip: '10.10.10.5',  model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw6', ip: '10.10.10.6',  model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw7', ip: '10.10.10.7',  model: 'ios', time: 'time', mtime: 'mtime', group: 'group1' },
       { name: 'sw8', ip: '10.10.10.8',  model: 'aos', time: 'time', mtime: 'mtime', group: 'group1' },
       { name: 'sw9', ip: '10.10.10.9',  model: 'aos', time: 'time', mtime: 'mtime', group: 'gr/oup1' }]
    )
    app.set(:nodes, @nodes)
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
