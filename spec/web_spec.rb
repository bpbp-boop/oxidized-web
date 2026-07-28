require_relative 'spec_helper'

# Keys added to every parsed configuration.  Individual test cases may
# override them by including the key in their own :expected hash.
WEB_CONFIG_DEFAULT_EXTRA = {
  node_cache_ttl: 10,
  min_threads: 1,
  max_threads: 8,
  conf_search_threads: 4
}.freeze

describe Oxidized::API::Web do
  describe "#parse_legacy_configuration" do
    test_cases = [
      {
        configuration: '192.168.1.100:9999',
        expected: { addr: '192.168.1.100', port: 9999, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'IP address and port'
      },
      {
        configuration: '[::1]:8080',
        expected: { addr: '[::1]', port: 8080, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'IPv6 address with port'
      },
      {
        configuration: '1234',
        expected: { addr: '', port: 1234, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'port only'
      },
      {
        configuration: '0.0.0.0:9999/api',
        expected: { addr: '0.0.0.0', port: 9999, uri_prefix: '/api',
                    vhosts: [], hide_node_vars: [] },
        description: 'host:port/prefix'
      },
      {
        configuration: '8888/v1',
        expected: { addr: '', port: 8888, uri_prefix: '/v1',
                    vhosts: [], hide_node_vars: [] },
        description: 'port/prefix'
      },
      {
        configuration: '127.0.0.1:3000/api/v2',
        expected: { addr: '127.0.0.1', port: 3000, uri_prefix: '/api/v2',
                    vhosts: [], hide_node_vars: [] },
        description: 'complex URI prefix'
      },
      {
        configuration: '127.0.0.1:3000/',
        expected: { addr: '127.0.0.1', port: 3000, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'empty URI prefix after slash'
      }
    ]

    test_cases.each do |test_case|
      it "should parse #{test_case[:description]} correctly" do
        result = Oxidized::API::Web.parse_legacy_configuration(test_case[:configuration])
        expect(result).must_equal WEB_CONFIG_DEFAULT_EXTRA.merge(test_case[:expected])
      end
    end
  end

  describe "#parse_new_configuration" do
    test_cases = [
      {
        configuration: Asetus::ConfigStruct.new(
          {
            'listen' => '0.0.0.0',
            'port' => 3000,
            'url_prefix' => '/api',
            'vhosts' => ['example.com', 'test.com'],
            'hide_node_vars' => %w[enable password]
          }
        ),
        expected: { addr: '0.0.0.0', port: 3000, uri_prefix: '/api',
                    vhosts: ["example.com", "test.com"],
                    hide_node_vars: %i[enable password] },
        description: 'all values provided'
      },
      {
        configuration: Asetus::ConfigStruct.new,
        expected: { addr: '127.0.0.1', port: 8888, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'all default values'
      },
      {
        configuration: Asetus::ConfigStruct.new(
          { 'hide_node_vars' => 'enable' }
        ),
        expected: { addr: '127.0.0.1', port: 8888, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [] },
        description: 'return an empty list when hide_node_vars not a hash'
      },
      {
        configuration: Asetus::ConfigStruct.new(
          {
            'node_cache_ttl' => 30,
            'min_threads' => 2,
            'max_threads' => 16,
            'conf_search_threads' => 8
          }
        ),
        expected: { addr: '127.0.0.1', port: 8888, uri_prefix: '/',
                    vhosts: [], hide_node_vars: [],
                    node_cache_ttl: 30, min_threads: 2, max_threads: 16,
                    conf_search_threads: 8 },
        description: 'performance tuning values'
      }
    ]

    test_cases.each do |test_case|
      it "should parse #{test_case[:description]} correctly" do
        result = Oxidized::API::Web.parse_configuration(test_case[:configuration])
        expect(result).must_equal WEB_CONFIG_DEFAULT_EXTRA.merge(test_case[:expected])
      end
    end

    it 'clamps config search concurrency to safe bounds' do
      too_low = Asetus::ConfigStruct.new('conf_search_threads' => 0)
      too_high = Asetus::ConfigStruct.new('conf_search_threads' => 100)
      invalid = Asetus::ConfigStruct.new('conf_search_threads' => 'invalid')

      expect(Oxidized::API::Web.parse_configuration(too_low)[:conf_search_threads]).must_equal 1
      expect(Oxidized::API::Web.parse_configuration(too_high)[:conf_search_threads]).must_equal 16
      expect(Oxidized::API::Web.parse_configuration(invalid)[:conf_search_threads]).must_equal 4
    end
  end
end
